import Foundation
import AVFoundation
import Combine
import CoreAudio
import AudioToolbox

enum AudioSnapshotError: Error { case notReady }

/// Captures the selected hardware input without changing the system default device.
@MainActor
final class AudioRecorderService: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isRecording = false
    private var engine: AVAudioEngine?
    private var sink: MicrophoneAudioSink?
    private var recordingURL: URL?
    private(set) var finalLiveWhisperSnapshot: LocalWhisperSnapshot?
    private var meterTimer: Timer?
    /// Called on the capture queue with an owned buffer. Consumers must be thread-safe.
    var liveBufferHandler: ((AVAudioPCMBuffer) -> Void)? {
        didSet { sink?.setLiveBufferHandler(liveBufferHandler) }
    }

    func start(deviceUID: String = "") async throws {
        guard !isRecording else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw ProviderError.message("Microphone access is required. Enable Cortala in System Settings → Privacy & Security → Microphone.")
        }
        try Task.checkCancellation()
        let capture = AVAudioEngine()
        let input = capture.inputNode
        if !deviceUID.isEmpty {
            guard let device = AudioInputDevice.available().first(where: { $0.id == deviceUID }), let unit = input.audioUnit else {
                throw ProviderError.message("The selected microphone is unavailable. Choose another input in Settings.")
            }
            var identifier = device.deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &identifier, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw ProviderError.message("Could not select the microphone (Core Audio \(status)).") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw ProviderError.message("The microphone has no usable audio input.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let output = try MicrophoneAudioSink(url: url, format: format)
        output.setLiveBufferHandler(liveBufferHandler)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in output.append(buffer) }
        do { try capture.start() }
        catch { input.removeTap(onBus: 0); output.close(); try? FileManager.default.removeItem(at: url); throw error }
        engine = capture
        sink = output
        recordingURL = url
        isRecording = true
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.level = self?.sink?.level ?? 0 }
        }
    }

    /// A finalized WAV containing the latest 24 seconds. The caller owns its temporary file.
    func snapshot() throws -> URL {
        guard isRecording, let sink else { throw ProviderError.message("No recording is active.") }
        return try sink.snapshot()
    }

    func liveWhisperSnapshot() throws -> LocalWhisperSnapshot {
        guard isRecording, let sink else { throw AudioSnapshotError.notReady }
        return try sink.timedSnapshot()
    }

    func stop(captureLiveWhisperTail: Bool = false) throws -> URL {
        guard let engine, let sink, let url = recordingURL, isRecording else { throw ProviderError.message("No recording is active.") }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        finalLiveWhisperSnapshot = captureLiveWhisperTail ? try? sink.timedSnapshot() : nil
        let error = sink.close()
        reset()
        if let error { throw error }
        return url
    }

    func cancel() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        sink?.close()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        reset()
    }

    private func reset() {
        meterTimer?.invalidate(); meterTimer = nil
        engine = nil; sink = nil; recordingURL = nil
        isRecording = false; level = 0
    }
}

/// The audio callback and snapshot reader synchronize file access and a bounded PCM ring.
private final class MicrophoneAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var samples: [[Float]]
    private var position = 0
    private var count = 0
    private var totalFrames: Int64 = 0
    private let capacity: Int
    private var error: Error?
    private var measuredLevel: Float = 0
    private var liveBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    var level: Float { lock.lock(); defer { lock.unlock() }; return measuredLevel }

    init(url: URL?, format: AVAudioFormat) throws {
        self.format = format
        capacity = Int(format.sampleRate * 24)
        samples = Array(repeating: Array(repeating: 0, count: capacity), count: Int(format.channelCount))
        if let url { file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved) }
    }

    func setLiveBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        liveBufferHandler = handler
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard error == nil else { return }
        do { try file?.write(from: buffer) } catch { self.error = error; return }
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        var energy: Float = 0
        for frame in 0..<frames {
            for channel in 0..<Int(format.channelCount) {
                let value = channels[channel][frame]
                samples[channel][position] = value
                if channel == 0 { energy += value * value }
            }
            position = (position + 1) % capacity
        }
        count = min(capacity, count + frames)
        totalFrames += Int64(frames)
        measuredLevel = frames > 0 ? min(1, sqrt(energy / Float(frames)) * 3) : 0
        if let handler = liveBufferHandler, let copy = buffer.ownedCopy() { handler(copy) }

    }

    func snapshot() throws -> URL { try timedSnapshot().url }
    func timedSnapshot() throws -> LocalWhisperSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        guard count > 0 else { throw AudioSnapshotError.notReady }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { throw ProviderError.message("Microphone samples are not ready yet.") }
        buffer.frameLength = AVAudioFrameCount(count)
        let first = (position - count + capacity) % capacity
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<count { channels[channel][frame] = samples[channel][(first + frame) % capacity] }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("preview-\(UUID().uuidString).wav")
        do {
            let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try output.write(from: buffer)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
        return LocalWhisperSnapshot(url: url, end: Double(totalFrames) / format.sampleRate)
    }

    @discardableResult func close() -> Error? {
        lock.lock(); defer { lock.unlock() }
        file = nil
        return error
    }
}

import ScreenCaptureKit
import CoreMedia

/// Captures system playback only. macOS asks for Screen & System Audio Recording access.
/// Microphone mixing and speaker diarization are deliberately separate capabilities.
@MainActor
final class SystemAudioRecorderService: ObservableObject {
    @Published private(set) var isRecording = false
    private var stream: SCStream?
    private var sink: SystemAudioSink?
    private var outputURL: URL?
    private let queue = DispatchQueue(label: "com.justwisper.system-audio")
    var liveBufferHandler: ((AVAudioPCMBuffer) -> Void)? {
        didSet { sink?.setLiveBufferHandler(liveBufferHandler) }
    }


    func start() async throws {
        guard !isRecording else { return }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw captureError(error) }
        guard let display = content.displays.first else { throw ProviderError.message("No display is available for system audio capture.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let output = try SystemAudioSink(url: url)
        output.setLiveBufferHandler(liveBufferHandler)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let capture = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try await capture.startCapture()
        } catch {
            output.cancel()
            try? FileManager.default.removeItem(at: url)
            throw captureError(error)
        }
        sink = output
        stream = capture
        outputURL = url
        isRecording = true
    }

    private func captureError(_ error: Error) -> Error {
        let issue = error as NSError
        if issue.domain == SCStreamErrorDomain, issue.code == SCStreamError.Code.userDeclined.rawValue {
            return ProviderError.message("System audio access was denied. In Meetings, open Screen & System Audio Recording settings to allow Cortala, or select Microphone as the audio source.")
        }
        return error
    }

    func snapshot() throws -> URL {
        guard isRecording, let sink else { throw ProviderError.message("No system audio recording is active.") }
        return try sink.snapshot()
    }

    func stop() async throws -> URL {
        guard let capture = stream, let output = sink, let url = outputURL else { throw ProviderError.message("No system audio recording is active.") }
        defer { stream = nil; sink = nil; outputURL = nil; isRecording = false }
        do {
            try await capture.stopCapture()
            // Flush callbacks already submitted on the capture queue before finalizing.
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
            try await output.finish()
            return url
        } catch {
            output.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func cancel() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        sink?.cancel()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        stream = nil
        sink = nil
        outputURL = nil
        isRecording = false
    }
}

private final class SystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var started = false
    private var captureError: Error?
    private var preview: MicrophoneAudioSink?
    private var previewConverter: AVAudioConverter?
    private var liveBufferHandler: ((AVAudioPCMBuffer) -> Void)?

    init(url: URL) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(input) else { throw ProviderError.message("Could not configure system audio recording.") }
        writer.add(input)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); defer { lock.unlock() }
        captureError = error
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard captureError == nil else { return }
        if !started {
            guard writer.startWriting() else { captureError = writer.error; return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        guard input.isReadyForMoreMediaData else {
            captureError = ProviderError.message("System audio could not be written quickly enough. Retry with a shorter recording.")
            return
        }
        if !input.append(sampleBuffer) { captureError = writer.error ?? ProviderError.message("System audio writing failed.") }
        appendPreview(sampleBuffer)

    }

    func setLiveBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        liveBufferHandler = handler
    }

    private func appendPreview(_ sample: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) else { return }
        source.frameLength = source.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(source.frameLength), into: source.mutableAudioBufferList) == noErr else { return }
        if preview == nil {
            preview = try? MicrophoneAudioSink(url: nil, format: mono)
            previewConverter = AVAudioConverter(from: format, to: mono)
        }
        guard let converter = previewConverter, let target = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: source.frameLength) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return source
        }
        if error == nil, target.frameLength > 0 {
            preview?.append(target)
            if let handler = liveBufferHandler, let copy = target.ownedCopy() { handler(copy) }
        }
    }

    func snapshot() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        if let captureError { throw captureError }
        guard let preview else { throw AudioSnapshotError.notReady }
        return try preview.snapshot()
    }

    private func prepareFinish() throws {
        lock.lock(); defer { lock.unlock() }
        if let captureError { throw captureError }
        guard started else { throw ProviderError.message("No system audio was captured. Play audio and check Screen & System Audio Recording permission.") }
        input.markAsFinished()
    }

    func finish() async throws {
        try prepareFinish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProviderError.message("Could not finish system audio recording.") }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        writer.cancelWriting()
    }
}


/// Coordinates two independent inputs and aligns their start times before mixing.
/// This records audible system playback; it does not identify individual speakers.
@MainActor
final class MeetingAudioService {
    let microphone = AudioRecorderService()
    private let system = SystemAudioRecorderService()
    private var source: MeetingAudioSource = .mixed
    private var micOffset = 0.0
    private var origin = Date()
    private var files: [URL] = []
    private(set) var recoveredFiles: [URL] = []
    private(set) var lastWarning: String?

    var level: Float { microphone.level }
    /// Mixed recordings use aligned rolling snapshots; raw asynchronous sources cannot be appended sequentially to a recognizer.
    var liveBufferHandler: ((AVAudioPCMBuffer) -> Void)? {
        didSet { configureLiveHandler() }
    }
    var liveMicrophoneBufferHandler: ((AVAudioPCMBuffer) -> Void)? { didSet { configureLiveHandler() } }
    var liveSystemBufferHandler: ((AVAudioPCMBuffer) -> Void)? { didSet { configureLiveHandler() } }
    private func configureLiveHandler() {
        microphone.liveBufferHandler = source != .system ? (liveMicrophoneBufferHandler ?? (source == .microphone ? liveBufferHandler : nil)) : nil
        system.liveBufferHandler = source != .microphone ? (liveSystemBufferHandler ?? (source == .system ? liveBufferHandler : nil)) : nil
    }


    func start(source: MeetingAudioSource, deviceUID: String = "") async throws {
        self.source = source
        origin = Date()
        configureLiveHandler()
        files = []
        recoveredFiles = []
        lastWarning = nil
        do {
            if source != .microphone {
                try await system.start()
                origin = Date()
            }
            try Task.checkCancellation()
            if source != .system {
                try await microphone.start(deviceUID: deviceUID)
                micOffset = source == .mixed ? max(0, Date().timeIntervalSince(origin)) : 0
            }
            try Task.checkCancellation()
        } catch {
            microphone.cancel()
            await system.cancel()
            throw error
        }
    }

    func liveWhisperSnapshot() async throws -> LocalWhisperSnapshot {
        if source == .microphone { return try microphone.liveWhisperSnapshot() }
        let url = try await snapshot()
        return LocalWhisperSnapshot(url: url, end: max(0, Date().timeIntervalSince(origin)))
    }

    /// Finalized recent audio for provisional captions; the final pass uses the full recording.
    func snapshot() async throws -> URL {
        if source == .microphone { return try microphone.snapshot() }
        if source == .system { return try system.snapshot() }
        var micSnapshot: URL?
        var systemSnapshot: URL?
        do { micSnapshot = try microphone.snapshot() } catch AudioSnapshotError.notReady { }
        do { systemSnapshot = try system.snapshot() }
        catch AudioSnapshotError.notReady { }
        catch {
            if let micSnapshot { try? FileManager.default.removeItem(at: micSnapshot) }
            throw error
        }
        guard let mic = micSnapshot, let playback = systemSnapshot else {
            if let available = micSnapshot ?? systemSnapshot { return available }
            throw AudioSnapshotError.notReady
        }
        defer { try? FileManager.default.removeItem(at: mic); try? FileManager.default.removeItem(at: playback) }
        let micFile = try AVAudioFile(forReading: mic)
        let systemFile = try AVAudioFile(forReading: playback)
        let micDuration = Double(micFile.length) / micFile.processingFormat.sampleRate
        let systemDuration = Double(systemFile.length) / systemFile.processingFormat.sampleRate
        return try await mix(microphone: mic, system: playback, offset: max(0, systemDuration - micDuration))
    }

    func stop() async throws -> URL {
        do {
            var micURL: URL?
            var systemURL: URL?
            var failures: [String] = []
            if source != .system {
                do { micURL = try microphone.stop(); files.append(micURL!) }
                catch { failures.append("Microphone: \(error.localizedDescription)") }
            }
            if source != .microphone {
                do { systemURL = try await system.stop(); files.append(systemURL!) }
                catch { failures.append("System audio: \(error.localizedDescription)") }
            }
            try Task.checkCancellation()
            if let micURL, let systemURL {
                do {
                    let url = try await mix(microphone: micURL, system: systemURL, offset: micOffset)
                    for file in files { try? FileManager.default.removeItem(at: file) }
                    files = []
                    return url
                } catch {
                    try Task.checkCancellation()
                    // Keep both originals when export fails. The app stages the second
                    // input as its own recoverable History entry.
                    recoveredFiles = [systemURL]
                    lastWarning = "Meeting mixing failed: \(error.localizedDescription) The microphone is being transcribed; the system track is saved separately in History for retry."
                    files = []
                    return micURL
                }
            }
            if let available = micURL ?? systemURL {
                if !failures.isEmpty { lastWarning = "Only one meeting input was captured. " + failures.joined(separator: " ") }
                files = []
                return available
            }
            throw ProviderError.message(failures.joined(separator: " "))
        } catch {
            await cancel()
            throw error
        }
    }

    func cancel() async {
        microphone.cancel()
        await system.cancel()
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
    }

    private func mix(microphone: URL, system: URL, offset: Double) async throws -> URL {
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (url, start) in [(system, 0.0), (microphone, offset)] {
            let asset = AVURLAsset(url: url)
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ProviderError.message("A meeting audio track could not be read.")
            }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audio, at: CMTime(seconds: start, preferredTimescale: 48_000))
            let parameter = AVMutableAudioMixInputParameters(track: track)
            // Leave headroom when both inputs contain the same sound.
            parameter.setVolume(0.5, at: .zero)
            parameters.append(parameter)
        }
        let output = system.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProviderError.message("Meeting audio mixing is unavailable.")
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        exporter.audioMix = audioMix
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        let cancellation = AssetExportCancellation(exporter)
        await withTaskCancellationHandler(operation: { await exporter.export() }, onCancel: { cancellation.cancel() })
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            try Task.checkCancellation()
            throw exporter.error ?? ProviderError.message("Could not mix meeting audio.")
        }
        return output
    }
}


/// AVAssetExportSession explicitly supports cancellation while export is in progress.
final class AssetExportCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

private extension AVAudioPCMBuffer {
    func ownedCopy() -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        result.frameLength = frameLength
        let from = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for index in from.indices {
            guard let source = from[index].mData, let destination = to[index].mData else { return nil }
            memcpy(destination, source, Int(from[index].mDataByteSize))
            to[index].mDataByteSize = from[index].mDataByteSize
        }
        return result
    }
}
