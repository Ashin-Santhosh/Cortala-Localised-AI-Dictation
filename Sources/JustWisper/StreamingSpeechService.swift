import Foundation
import Speech
import AVFoundation

/// Source labels identify capture inputs, never people.
enum StreamingSpeechSource: String, Hashable, Sendable {
    case microphone, system
    var title: String { self == .microphone ? "Microphone" : "System audio" }
}

/// Partial hypotheses replace the same utterance; final callbacks cannot duplicate it.
struct StreamingTranscriptAccumulator {
    struct Utterance {
        var id: UUID
        var source: StreamingSpeechSource
        var text: String
        var isFinal: Bool
    }
    private(set) var utterances: [Utterance] = []
    private(set) var discardedUtterances = false
    var retainFullTranscript = false
    mutating func update(id: UUID, source: StreamingSpeechSource, text: String, isFinal: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let index = utterances.firstIndex(where: { $0.id == id }) {
            guard !utterances[index].isFinal else { return }
            utterances[index].text = text
            utterances[index].isFinal = isFinal
        } else { utterances.append(Utterance(id: id, source: source, text: text, isFinal: isFinal)) }
        if !retainFullTranscript {
            while utterances.count > 100 || (utterances.reduce(0) { $0 + $1.text.count } > 20_000 && utterances.count > 1) {
                utterances.removeFirst(); discardedUtterances = true
            }
        }
    }
    func rendered(labelSources: Bool) -> String {
        utterances.map { (labelSources ? $0.source.title + ": " : "") + $0.text }.joined(separator: "\n")
    }
}

/// A partial hypothesis is never promoted to a final dictation by ending audio
/// or by reaching a deadline. Every utterance must receive Apple's final flag.
enum StreamingFinalizationState: Equatable {
    case waiting, ready, empty, incomplete, failed
    static func evaluate(_ transcript: StreamingTranscriptAccumulator, pendingRequests: Int, failed: Bool) -> Self {
        if failed { return .failed }
        if pendingRequests > 0 { return .waiting }
        if transcript.utterances.isEmpty { return .empty }
        if transcript.discardedUtterances || transcript.utterances.contains(where: { !$0.isFinal }) { return .incomplete }
        return .ready
    }
}

/// AVAudioEngine/ScreenCaptureKit own their callback memory. Copy before crossing queues.
enum SpeechAudioCopy {
    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0, let target = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        target.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        guard sourceBuffers.count == targetBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard let input = sourceBuffers[index].mData, let output = targetBuffers[index].mData,
                  targetBuffers[index].mDataByteSize >= sourceBuffers[index].mDataByteSize else { return nil }
            memcpy(output, input, Int(sourceBuffers[index].mDataByteSize))
            targetBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return target
    }
}

final class SpeechBufferTransfer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Capture callbacks may run off the main actor. Close and drain atomically so
/// Stop includes every accepted real buffer before asking Speech to finalize.
final class SpeechAudioIngress: @unchecked Sendable {
    struct Item { let buffer: SpeechBufferTransfer; let source: StreamingSpeechSource }
    private let lock = NSLock()
    private var run: UUID?
    private var queued: [Item] = []
    func open(_ id: UUID) { lock.lock(); defer { lock.unlock() }; run = id; queued = [] }
    func enqueue(_ item: Item, expectedRun: UUID? = nil) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard let run else { return nil }
        guard expectedRun == nil || expectedRun == run else { return nil }
        queued.append(item); return run
    }
    func drain(_ id: UUID, close: Bool = false) -> [Item] {
        lock.lock(); defer { lock.unlock() }
        guard run == id else { return [] }
        if close { run = nil }
        let result = queued; queued = []; return result
    }
}

/// Apple's actual incremental Speech API. It cannot use a network recognition fallback.
/// Fast dictation can explicitly await genuine finals; meeting captions remain provisional.
@MainActor
final class StreamingSpeechService {
    private final class Session {
        let recognizer: SFSpeechRecognizer
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var utteranceID = UUID()
        var generation = UUID()
        var failures = 0
        var disabled = false
        var reportedNoSpeech = false
        var technicalFailure = false
        var receivedAudio = false
        init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }
    }
    private var sessions: [StreamingSpeechSource: Session] = [:]
    private var accumulator = StreamingTranscriptAccumulator()
    private var active = false
    private var finishing = false
    private var runID = UUID()
    private nonisolated let ingress = SpeechAudioIngress()
    private var labelSources = false
    private var vocabulary: [String] = []
    private var update: ((String) -> Void)?
    private var warning: ((String) -> Void)?

    /// Called only after an explicit recording action with Apple captions enabled.
    func start(language: String, vocabulary: [String], sources: [StreamingSpeechSource], retainFullTranscript: Bool = false,
               onUpdate: @escaping (String) -> Void, onError: @escaping (String) -> Void) async throws {
        stop()
        let authorization: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else { authorization = SFSpeechRecognizer.authorizationStatus() }
        try Task.checkCancellation()
        guard authorization == .authorized else {
            throw ProviderError.message("Apple Speech requires Speech Recognition permission. Enable it for Cortala in System Settings → Privacy & Security → Speech Recognition.")
        }
        let locale = try Self.supportedOnDeviceLocale(language: language)
        var next: [StreamingSpeechSource: Session] = [:]
        for source in sources {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                throw ProviderError.message("Apple on-device speech is unavailable for \(locale.identifier). Choose a supported language or Local Whisper.")
            }
            next[source] = Session(recognizer: recognizer)
        }
        self.vocabulary = Array(vocabulary.filter { !$0.isEmpty }.prefix(100))
        sessions = next; accumulator = StreamingTranscriptAccumulator(retainFullTranscript: retainFullTranscript)
        labelSources = sources.count > 1; update = onUpdate; warning = onError; active = true
        runID = UUID(); ingress.open(runID)
        // A request is created when the first real buffer arrives; no audio is synthesized.
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer, source: StreamingSpeechSource) {
        append(buffer, source: source, expectedRun: nil)
    }

    /// Bind capture callbacks to this recording, including callbacks that were
    /// already in flight when capture stopped and a later run began.
    func audioSink(source: StreamingSpeechSource) -> @Sendable (AVAudioPCMBuffer) -> Void {
        let id = runID
        return { [weak self] in self?.append($0, source: source, expectedRun: id) }
    }

    private nonisolated func append(_ buffer: AVAudioPCMBuffer, source: StreamingSpeechSource, expectedRun: UUID?) {
        guard let copied = SpeechAudioCopy.copy(buffer) else { return }
        let transfer = SpeechBufferTransfer(copied)
        guard let id = ingress.enqueue(.init(buffer: transfer, source: source), expectedRun: expectedRun) else { return }
        Task { @MainActor [weak self] in self?.consumeQueued(id) }
    }

    private func consumeQueued(_ id: UUID) {
        guard active, runID == id, !finishing else { return }
        for item in ingress.drain(id) { consume(item.buffer.buffer, source: item.source) }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, source: StreamingSpeechSource) {
        guard active, !finishing, let session = sessions[source], !session.disabled else { return }
        if session.request == nil { beginUtterance(session, source: source) }
        if let request = session.request {
            request.append(buffer)
            session.receivedAudio = true
        }
    }

    private func beginUtterance(_ session: Session, source: StreamingSpeechSource) {
        guard active, session.recognizer.supportsOnDeviceRecognition else {
            session.disabled = true
            warning?("On-device recognition became unavailable for \(source.title). Live captions stopped; no cloud fallback was used.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = vocabulary
        request.taskHint = .dictation
        session.utteranceID = UUID(); session.generation = UUID()
        let id = session.utteranceID, generation = session.generation
        session.request = request
        session.task = session.recognizer.recognitionTask(with: request) { [weak self, weak session] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            let noSpeech = error.map(NoSpeechPolicy.isAppleNoSpeech) ?? false
            Task { @MainActor in
                guard let self, let session, self.active, session.generation == generation else { return }
                if let text, !text.isEmpty {
                    self.accumulator.update(id: id, source: source, text: text, isFinal: final)
                    self.update?(self.accumulator.rendered(labelSources: self.labelSources))
                    session.failures = 0
                }
                if final || failure != nil {
                    session.request?.endAudio()
                    session.request = nil
                    session.task = nil
                    // Next real audio buffer starts a fresh utterance after normal
                    // completion or a bounded retry; old callbacks cannot edit it.
                    session.generation = UUID()
                    if let failure, !final {
                        if noSpeech {
                            session.reportedNoSpeech = true
                            if self.finishing { session.disabled = true }
                            return
                        }
                        session.technicalFailure = true
                        session.failures += 1
                        if self.finishing || session.failures >= 3 { session.disabled = true }
                        self.warning?("\(source.title) live captions \(session.disabled ? "stopped" : "restarting"): \(failure). The full recording continues; no cloud fallback was used.")
                    }
                }
            }
        }
    }

    /// Call after capture has stopped. Success contains only real final Speech
    /// results; an unavailable recognizer, partial tail or timeout is explicit.
    func finish(timeout: TimeInterval = 5) async throws -> String {
        guard active, !finishing else { throw ProviderError.message("On-device dictation is not running.") }
        let id = runID
        for item in ingress.drain(id, close: true) { consume(item.buffer.buffer, source: item.source) }
        finishing = true
        defer { if runID == id { stop() } }
        for session in sessions.values { session.request?.endAudio() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout.isFinite ? max(0, min(timeout, 30)) : 5))
        while true {
            try Task.checkCancellation()
            guard active, runID == id else { throw CancellationError() }
            let state = StreamingFinalizationState.evaluate(accumulator,
                pendingRequests: sessions.values.filter { $0.request != nil }.count,
                failed: sessions.values.contains { $0.technicalFailure || !$0.receivedAudio || $0.disabled })
            switch state {
            case .ready: return accumulator.rendered(labelSources: labelSources)
            case .empty: throw NoSpeechDetected()
            case .incomplete, .failed:
                if accumulator.utterances.isEmpty, !sessions.isEmpty,
                   sessions.values.allSatisfy({ $0.reportedNoSpeech && !$0.technicalFailure }) { throw NoSpeechDetected() }
                throw ProviderError.message("On-device dictation could not finalize every utterance. The recording is preserved for retry; no partial text was inserted.")
            case .waiting: break
            }
            guard clock.now < deadline else { throw ProviderError.message("On-device dictation timed out waiting for final words. The recording is preserved for retry; no partial text was inserted.") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func stop() {
        _ = ingress.drain(runID, close: true)
        runID = UUID(); finishing = false
        active = false
        for session in sessions.values {
            session.generation = UUID()
            session.request?.endAudio()
            session.task?.cancel()
        }
        sessions = [:]; update = nil; warning = nil
    }

    private static func supportedOnDeviceLocale(language: String) throws -> Locale {
        let requested = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = Locale.current
        let languageCode = requested.isEmpty || requested == "auto" ? (current.language.languageCode?.identifier ?? "en") : Locale(identifier: requested).language.languageCode?.identifier ?? requested
        let supported = SFSpeechRecognizer.supportedLocales().filter { $0.language.languageCode?.identifier == languageCode }
        let preferred = [requested.replacingOccurrences(of: "-", with: "_"), current.identifier, languageCode == "en" ? "en_US" : ""]
        let candidates = supported.sorted { a, b in
            let ai = preferred.firstIndex(of: a.identifier) ?? Int.max
            let bi = preferred.firstIndex(of: b.identifier) ?? Int.max
            return ai == bi ? a.identifier < b.identifier : ai < bi
        }
        for locale in candidates {
            if SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true { return locale }
        }
        throw ProviderError.message("Apple on-device live captions are unavailable for language '\(languageCode)' on this Mac. Choose a supported caption language or selected-provider previews explicitly. No cloud fallback was used.")
    }
}
