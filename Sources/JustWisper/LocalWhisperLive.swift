import AVFoundation
import Darwin
import Foundation

struct LocalWhisperSnapshot { var url: URL; var end: Double }
struct LocalWhisperWord: Codable, Equatable { var start: Double; var end: Double; var text: String }
struct LocalWhisperReply: Decodable { var ready: Bool?; var `protocol`: Int?; var segments: [LocalWhisperWord]?; var silent: Bool? }

/// Timestamp overlap replaces recent hypotheses instead of appending every decode.
/// Older text is bounded; a discarded prefix can never be returned as a complete final.
struct LocalWhisperAccumulator {
    private(set) var committed: [LocalWhisperWord] = []
    private(set) var provisional: [LocalWhisperWord] = []
    private(set) var coveredUntil = 0.0
    private(set) var complete = true
    private(set) var truncated = false
    private var windowStart = 0.0
    mutating func update(_ words: [LocalWhisperWord], start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start, end >= coveredUntil else { return }
        if start > coveredUntil + 0.25 { complete = false }
        var incoming = words.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.end <= end - start + 0.5 }
            .map { LocalWhisperWord(start: $0.start + start, end: $0.end + start, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if start > windowStart {
            // Commit only audio that has actually left the rolling window.
            // Resampling can shift a growing startup window by a fraction of
            // a sample; committing two seconds ahead repeats its opening words.
            let candidates = provisional.filter { $0.end <= start }
            if !candidates.isEmpty {
                // Acoustic word timestamps drift between windows. Align a real
                // textual suffix within the overlapping audio before committing.
                func token(_ text: String) -> String { text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                var matched: Int?
                let maximum = min(12, candidates.count, incoming.count)
                if maximum > 0 {
                    search: for length in stride(from: maximum, through: 1, by: -1) {
                        let suffix = Array(candidates.suffix(length))
                        for offset in 0...min(12, incoming.count - length) {
                            let range = offset..<(offset + length)
                            if zip(suffix, incoming[range]).allSatisfy({ token($0.text) == token($1.text) }),
                               incoming[offset].start < (suffix.last?.end ?? 0),
                               abs((suffix.last?.end ?? 0) - incoming[offset + length - 1].end) < 2 {
                                matched = offset + length; break search
                            }
                        }
                    }
                }
                committed += candidates
                if let matched { incoming.removeFirst(matched) }
                else {
                    let boundary = committed.last?.end ?? start
                    // No textual overlap is expected when the new window
                    // begins after the committed word. Preserve a genuinely
                    // repeated next word rather than matching it by text alone.
                    if let first = incoming.first, first.start < boundary - 0.05 { complete = false }
                    incoming.removeAll { $0.end <= boundary }
                }
            }
        }
        // A repeated window (including Stop's final decode) can contain words
        // already committed by a previous window. Never restore that prefix.
        if let last = committed.last {
            incoming.removeAll { $0.end <= last.end }
            // A re-decode can move the same boundary word slightly forward.
            // A new occurrence starting at or after the boundary is genuine.
            if let first = incoming.first, first.start < last.end - 0.08,
               first.text.compare(last.text, options: .caseInsensitive) == .orderedSame,
               first.end <= last.end + 0.35 {
                incoming.removeFirst()
            }
        }
        provisional = incoming
        windowStart = start; coveredUntil = end
        while committed.count > 3000 || committed.reduce(0, { $0 + $1.text.utf8.count }) > 40_000 {
            committed.removeFirst(); truncated = true
        }
    }
    var text: String { (committed + provisional).map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    func finalText(at end: Double) throws -> String {
        guard complete, !truncated, abs(coveredUntil - end) <= 0.15 else { throw ProviderError.message("Live recognition did not cover all audio; completing the saved recording locally.") }
        guard !NoSpeechPolicy.isEmptyTranscript(text) else { throw NoSpeechDetected() }
        return text
    }
}

enum LocalWhisperRuntime {
    static var executable: URL? {
        let resource = Bundle.main.resourceURL?.appendingPathComponent("bin/justwisper-live")
        if let resource, FileManager.default.isExecutableFile(atPath: resource.path) { return resource }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/live-whisper/justwisper-live-native")
        if FileManager.default.isExecutableFile(atPath: development.path) { return development }
        #endif
        return nil
    }
    static func available(model: String) -> Bool { executable != nil && model.hasPrefix("/") && FileManager.default.isReadableFile(atPath: model) }
}

/// One resident process, one request in flight. Its serial I/O queue never stores
/// microphone callbacks or unbounded snapshots. Only local PCM crosses the pipe.
protocol ResidentWhisperServing: AnyObject, Sendable {
    func ready() async throws -> LocalWhisperReply
    func infer(_ samples: [Float]) async throws -> LocalWhisperReply
    func terminate()
}

final class ResidentWhisperProcess: ResidentWhisperServing, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let queue = DispatchQueue(label: "com.justwisper.resident-whisper", qos: .userInitiated)
    private var pending = Data()
    init(executable: URL, model: String, language: String) throws {
        process.executableURL = executable; process.arguments = [model, language.isEmpty ? "auto" : language]
        process.environment = LocalProcessEnvironment.sanitized(ProcessInfo.processInfo.environment)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func ready() async throws -> LocalWhisperReply { try await exchange(nil, timeout: 120) }
    func infer(_ samples: [Float]) async throws -> LocalWhisperReply {
        guard (1600...256_000).contains(samples.count), samples.allSatisfy(\.isFinite) else { throw ProviderError.message("Invalid local audio window.") }
        var count = UInt32(samples.count).littleEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        samples.withUnsafeBytes { frame.append(contentsOf: $0) }
        return try await exchange(frame, timeout: 45)
    }
    private func exchange(_ frame: Data?, timeout: Double) async throws -> LocalWhisperReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if let frame { try self.input.fileHandleForWriting.write(contentsOf: frame) }
                    let deadline = Date().addingTimeInterval(timeout)
                    while true {
                        if let newline = self.pending.firstIndex(of: 10) {
                            let line = self.pending.prefix(upTo: newline)
                            self.pending.removeSubrange(...newline)
                            continuation.resume(returning: try JSONDecoder().decode(LocalWhisperReply.self, from: line)); return
                        }
                        guard Date() < deadline else { throw ProviderError.message("Local live recognition timed out. The full recording is preserved for local recovery.") }
                        var descriptor = pollfd(fd: self.output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                        let result = poll(&descriptor, 1, 100)
                        if result < 0 && errno != EINTR { throw ProviderError.message("Local live recognition pipe failed.") }
                        if result > 0 {
                            let data = self.output.fileHandleForReading.availableData
                            guard !data.isEmpty else { throw ProviderError.message("Local live recognition stopped. The recording continues for recovery.") }
                            self.pending.append(data)
                            guard self.pending.count <= 262_144 else { throw ProviderError.message("Local live recognition response exceeded its bound.") }
                        }
                    }
                } catch { self.terminate(); continuation.resume(throwing: error) }
            }
        }
    }
    func terminate() {
        if process.isRunning { process.terminate(); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
    deinit { terminate() }
}

@MainActor final class LocalWhisperLiveService: ObservableObject {
    @Published private(set) var state = "Local live model not loaded"
    @Published private(set) var loadSeconds: Double?
    @Published private(set) var inferenceSeconds: Double?
    private var worker: (any ResidentWhisperServing)?
    private let makeWorker: (URL, String, String) throws -> any ResidentWhisperServing
    private let runtime: (String) -> URL?
    private var identity = ""
    private var warmTask: Task<Void, Error>?
    private var task: Task<Void, Never>?
    private var session = UUID()
    private var accumulator = LocalWhisperAccumulator()
    private var failure = false
    private var warmingID = UUID()
    var onStateChange: (() -> Void)?
    var isReady: Bool { worker != nil && warmTask == nil }
    init(makeWorker: @escaping (URL, String, String) throws -> any ResidentWhisperServing = { try ResidentWhisperProcess(executable: $0, model: $1, language: $2) },
         runtime: @escaping (String) -> URL? = { LocalWhisperRuntime.available(model: $0) ? LocalWhisperRuntime.executable : nil }) {
        self.makeWorker = makeWorker; self.runtime = runtime
    }

    func warm(model: String, language: String) async throws {
        let key = model + "\n" + language
        if identity == key {
            if let warmTask { try await warmTask.value }
            if worker != nil { return }
        }
        release()
        guard let executable = runtime(model) else {
            state = "Local live requires the bundled helper and a downloaded GGML model"; onStateChange?()
            throw ProviderError.message(state)
        }
        identity = key; state = "Warming local Whisper…"; onStateChange?()
        let id = UUID(); warmingID = id
        let began = Date()
        let next: any ResidentWhisperServing
        do { next = try makeWorker(executable, model, language) }
        catch {
            identity = ""; state = "Local live model unavailable: \(error.localizedDescription)"; onStateChange?()
            throw error
        }
        worker = next
        let warming = Task {
            let reply = try await next.ready()
            guard reply.ready == true, reply.protocol == 1 else { throw ProviderError.message("Unsupported local live protocol.") }
        }
        warmTask = warming
        do {
            try await warming.value
            guard warmingID == id else { throw CancellationError() }
            warmTask = nil; loadSeconds = Date().timeIntervalSince(began)
            state = "Local Whisper ready · model resident in memory"; onStateChange?()
        } catch {
            if warmingID == id { worker = nil; warmTask = nil; identity = ""; state = "Local live model unavailable: \(error.localizedDescription)"; onStateChange?() }
            next.terminate(); throw error
        }
    }
    func start(model: String, language: String, updateInterval: Duration = .milliseconds(1500),
               snapshot: @escaping () async throws -> LocalWhisperSnapshot,
               onUpdate: @escaping (String) -> Void, onError: @escaping (String) -> Void) async throws {
        stopSession()
        try await warm(model: model, language: language)
        try Task.checkCancellation()
        let id = UUID(); session = id; accumulator = LocalWhisperAccumulator(); failure = false
        task = Task {
            while !Task.isCancelled && session == id {
                do {
                    try await Task.sleep(for: updateInterval)
                    let snapshot = try await snapshot()
                    let text = try await decode(snapshot, session: id)
                    guard !Task.isCancelled, session == id else { return }
                    onUpdate(String(text.suffix(12_000)))
                } catch is CancellationError { return }
                catch AudioSnapshotError.notReady { continue }
                catch {
                    guard session == id, !Task.isCancelled else { return }
                    failure = true; onError(error.localizedDescription + " Stop will finish the saved recording locally."); return
                }
            }
        }
    }
    private func decode(_ snapshot: LocalWhisperSnapshot, session id: UUID) async throws -> String {
        defer { try? FileManager.default.removeItem(at: snapshot.url) }
        let audio = try await Task.detached(priority: .userInitiated) { try Self.samples(snapshot.url) }.value
        guard session == id, let worker else { throw CancellationError() }
        let start = max(0, snapshot.end - Double(audio.count) / 16000)
        let began = Date()
        let reply: LocalWhisperReply
        do { reply = try await worker.infer(audio) }
        catch {
            guard session == id else { throw CancellationError() }
            worker.terminate()
            if self.worker === worker { self.worker = nil; identity = ""; state = "Local live recognition unavailable; the full recording is preserved"; onStateChange?() }
            throw error
        }
        guard session == id else { throw CancellationError() }
        inferenceSeconds = Date().timeIntervalSince(began); onStateChange?()
        accumulator.update(reply.segments ?? [], start: start, end: snapshot.end)
        return accumulator.text
    }
    /// Capture passes its final bounded ring before closing the recorder. Waiting
    /// for the current request avoids a second queued inference or dropped tail.
    func finish(_ snapshot: LocalWhisperSnapshot) async throws -> String {
        let id = session
        task?.cancel(); let pending = task; task = nil
        await pending?.value
        guard session == id, !failure else { try? FileManager.default.removeItem(at: snapshot.url); throw ProviderError.message("Local live recognition needs full-audio recovery.") }
        _ = try await decode(snapshot, session: id)
        return try accumulator.finalText(at: snapshot.end)
    }
    func stopSession() { session = UUID(); task?.cancel(); task = nil; accumulator = LocalWhisperAccumulator(); failure = false }
    func release() {
        stopSession(); warmingID = UUID(); warmTask?.cancel(); warmTask = nil
        worker?.terminate(); worker = nil; identity = ""; state = "Local live model released"; onStateChange?()
    }
    nonisolated static func samples(_ url: URL) throws -> [Float] {
        let source = try AVAudioFile(forReading: url)
        // Snapshot is 24 seconds maximum. Crop before resampling to cap CPU/memory.
        source.framePosition = max(0, source.length - AVAudioFramePosition(source.processingFormat.sampleRate * 12))
        guard let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(source.length - source.framePosition)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000) else { throw ProviderError.message("Live audio conversion unavailable.") }
        try source.read(into: input)
        var fed = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        guard let pcm = output.floatChannelData else { throw ProviderError.message("No live PCM samples.") }
        var values = Array(UnsafeBufferPointer(start: pcm[0], count: Int(output.frameLength)))
        values.withUnsafeMutableBufferPointer { QuietSpeechGain.apply(to: $0) }
        if values.count < 1600 { values += Array(repeating: 0, count: 1600 - values.count) }
        return values
    }
}
