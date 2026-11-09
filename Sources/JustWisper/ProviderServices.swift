import Foundation
import Security
import AVFoundation

struct TranscriptionRequest {
    var audioURL: URL
    var endpoint: URL?
    var apiKey: String
    var model: String
    var language: String
    var vocabulary: String
    var localExecutable: String
    var localModel: String
    var provider: String
}

enum ProviderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum ProviderHTTP {
    /// Endpoints are exact URLs, not base URLs. Plain HTTP is permitted only for local model servers.
    static func validate(_ url: URL) throws {
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        guard url.scheme == "https" || (url.scheme == "http" && local), url.host != nil,
              url.user == nil, url.password == nil else {
            throw ProviderError.message("Use an HTTPS endpoint, or HTTP on localhost for a local model server.")
        }
    }

    static func send(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.message("The provider returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not surface response bodies: providers can echo submitted audio text or credentials.
            let hint: String
            switch http.statusCode {
            case 401, 403: hint = "Check the API key and model access."
            case 413: hint = "The audio file exceeds this provider's upload limit."
            case 429: hint = "Check your quota or retry later."
            default: hint = "Check the endpoint and provider status."
            }
            throw ProviderError.message("Provider request failed (HTTP \(http.statusCode)). \(hint)")
        }
        return data
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum TranscriptionService {
    static func transcribe(_ request: TranscriptionRequest) async throws -> String {
        try await transcribeDetailed(request).text
    }
    static func transcribe(request: TranscriptionRequest) async throws -> String { try await transcribe(request) }

    static func transcribeDetailed(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        guard request.provider == "local" || request.provider == "cloud" else { throw ProviderError.message("Unknown transcription provider.") }
        if request.provider == "local" { try validateLocal(request) }
        else {
            guard let endpoint = request.endpoint else { throw ProviderError.message("Enter a transcription endpoint.") }
            try ProviderHTTP.validate(endpoint)
            guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.message("Enter a transcription model.") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper-transcribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await AudioConversion.audioSource(input: request.audioURL, directory: directory)
        let wav = directory.appendingPathComponent("input.wav")
        let conversion = Task.detached { try AudioConversion.toWhisperWAV(input: source, output: wav, boostQuietSpeech: request.provider == "local") }
        try await withTaskCancellationHandler(operation: { try await conversion.value }, onCancel: { conversion.cancel() })
        try Task.checkCancellation()
        let profile = SpeechProviderCapabilities.resolve(endpoint: request.endpoint, model: request.model)
        // PCM mono 16 kHz is 32 kB/s: a 10 minute chunk remains below the 25 MB limit.
        let chunkSeconds = request.provider == "local" ? 600.0 : min(600, Double(profile.maximumUploadBytes - 100_000) / 32_000)
        let file = try AVAudioFile(forReading: wav)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let ranges = AudioChunkPlan.ranges(duration: duration, maximumDuration: chunkSeconds, overlap: 2)
        guard !ranges.isEmpty else { return TranscriptionResult(text: "", segments: []) }
        var results: [(AudioChunkRange, TranscriptionResult)] = []
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let chunk = directory.appendingPathComponent("chunk-\(index).wav")
            try AudioChunkPlan.write(input: wav, output: chunk, range: range)
            var next = request
            next.audioURL = chunk
            let result = request.provider == "local" ? try await local(next, directory: directory, index: index) : try await cloud(next, capabilities: profile)
            results.append((range, result))
            try? FileManager.default.removeItem(at: chunk)
        }
        return TranscriptMerger.merge(results)
    }

    static func cloudRequest(_ request: TranscriptionRequest, capabilities: SpeechProviderCapabilities) throws -> URLRequest {
        guard let endpoint = request.endpoint else { throw ProviderError.message("Enter a transcription endpoint.") }
        try ProviderHTTP.validate(endpoint)
        let attributes = try FileManager.default.attributesOfItem(atPath: request.audioURL.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 <= capabilities.maximumUploadBytes else {
            throw ProviderError.message("The audio chunk exceeds this provider's upload limit.")
        }
        let boundary = "Cortala-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", request.model)
        field("response_format", capabilities.responseFormat)
        if capabilities.diarization { field("chunking_strategy", "auto") }
        if !request.language.isEmpty && request.language != "auto" { field("language", request.language) }
        if capabilities.supportsPrompt && !request.vocabulary.isEmpty { field("prompt", request.vocabulary) }
        if capabilities.responseFormat == "verbose_json" { field("timestamp_granularities[]", "segment") }
        let ext = request.audioURL.pathExtension.lowercased()
        let mime = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "mp4": "audio/mp4", "flac": "audio/flac", "ogg": "audio/ogg", "webm": "audio/webm"][ext] ?? "application/octet-stream"
        let safeExtension = !ext.isEmpty && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? ext : "audio"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(safeExtension)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(try Data(contentsOf: request.audioURL))
        append("\r\n--\(boundary)--\r\n")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !request.apiKey.isEmpty { urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = body
        return urlRequest
    }

    private static func cloud(_ request: TranscriptionRequest, capabilities: SpeechProviderCapabilities) async throws -> TranscriptionResult {
        let data = try await ProviderHTTP.send(cloudRequest(request, capabilities: capabilities))
        return try TranscriptionResult.decodeCloud(data)
    }

    private static func validateLocal(_ request: TranscriptionRequest) throws {
        let executable = NSString(string: request.localExecutable).expandingTildeInPath
        let model = NSString(string: request.localModel).expandingTildeInPath
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProviderError.message("Choose the executable whisper-cli file from a whisper.cpp installation.")
        }
        guard model.hasPrefix("/"), FileManager.default.isReadableFile(atPath: model) else {
            throw ProviderError.message("Choose a readable whisper.cpp GGML model file.")
        }
    }

    private static func local(_ request: TranscriptionRequest, directory: URL, index: Int) async throws -> TranscriptionResult {
        let executable = NSString(string: request.localExecutable).expandingTildeInPath
        let model = NSString(string: request.localModel).expandingTildeInPath
        let output = directory.appendingPathComponent("transcript-\(index)")
        // Ask the decoder for word-sized segments with its own acoustic timings.
        // Sentence-sized segments can span several speaker turns and cannot be
        // assigned an individual speaker without inventing word timestamps.
        var arguments = ["-m", model, "-f", request.audioURL.path, "-oj", "-ml", "1", "-sow", "-of", output.path, "-l", request.language.isEmpty ? "auto" : request.language, "-nt"]
        if !request.vocabulary.isEmpty { arguments += ["--prompt", request.vocabulary] }
        try await LocalProcess.run(executable: executable, arguments: arguments, directory: directory)
        return try TranscriptionResult.decodeWhisper(Data(contentsOf: output.appendingPathExtension("json")))
    }
}

enum RewriteService {
    static func rewrite(text: String, instruction: String, endpoint: URL, apiKey: String, model: String, context: String? = nil) async throws -> String {
        let request = try RewriteProtocol.request(text: text, instruction: instruction, endpoint: endpoint, apiKey: apiKey, model: model, context: context)
        let data = try await ProviderHTTP.send(request)
        return try RewriteProtocol.decode(data, endpoint: endpoint)
    }
}

enum AudioConversion {
    /// AVAudioFile accepts audio containers. Extract a movie's audio track first.
    static func audioSource(input: URL, directory: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: input)) != nil { return input }
        let asset = AVURLAsset(url: input)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ProviderError.message("This file contains no readable audio track.")
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProviderError.message("This file's audio cannot be extracted for local transcription.")
        }
        let output = directory.appendingPathComponent("extracted.m4a")
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        let cancellation = AssetExportCancellation(exporter)
        await withTaskCancellationHandler(operation: { await exporter.export() }, onCancel: { cancellation.cancel() })
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw exporter.error ?? ProviderError.message("Could not extract the file's audio track.")
        }
        return output
    }

    static func toWhisperWAV(input: URL, output: URL, boostQuietSpeech: Bool = false) throws {
        let source: AVAudioFile
        do { source = try AVAudioFile(forReading: input) }
        catch { throw ProviderError.message("Could not open the audio file: \(error)") }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source.processingFormat, to: format) else {
            throw ProviderError.message("This audio format cannot be converted for local transcription.")
        }
        let destination: AVAudioFile
        do {
            destination = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw ProviderError.message("Could not create the transcription WAV: \(error)") }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw ProviderError.message("Could not allocate audio conversion buffers.") }
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { requestedPackets, status in
                let remaining = source.length - source.framePosition
                guard remaining > 0 else { status.pointee = .endOfStream; return nil }
                let frames = AVAudioFrameCount(min(Int64(min(8192, max(1, requestedPackets))), remaining))
                do {
                    try source.read(into: inputBuffer, frameCount: frames)
                    status.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                    return inputBuffer.frameLength == 0 ? nil : inputBuffer
                } catch {
                    readError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw ProviderError.message("Could not read audio samples: \(readError)") }
            if let error { throw ProviderError.message("Sample-rate conversion failed (\(error.domain) \(error.code)): \(error.localizedDescription)") }
            if outputBuffer.frameLength > 0 {
                if boostQuietSpeech, let samples = outputBuffer.floatChannelData?[0] {
                    QuietSpeechGain.apply(to: .init(start: samples, count: Int(outputBuffer.frameLength)))
                }
                do { try destination.write(from: outputBuffer) }
                catch { throw ProviderError.message("Could not write converted audio samples: \(error)") }
            }
            if status == .endOfStream { break }
            if status == .error { throw ProviderError.message("Audio conversion failed.") }
        }
    }
}

enum LocalProcessEnvironment {
    /// Keep ordinary locale/home settings while preventing inherited loader or
    /// backend overrides from changing the selected local speech runtime.
    static func sanitized(_ inherited: [String: String]) -> [String: String] {
        var result = inherited.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("GGML_") && key != "LD_PRELOAD" && key != "LD_LIBRARY_PATH"
        }
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return result
    }
}

private enum LocalProcess {
    static func run(executable: String, arguments: [String], directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = LocalProcessEnvironment.sanitized(ProcessInfo.processInfo.environment)
        // File-backed output avoids pipe deadlocks on long model loading logs.
        let log = directory.appendingPathComponent("process.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(1800)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() > deadline { throw ProviderError.message("Local transcription timed out after 30 minutes.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            process.terminate()
            // Wait briefly for termination before releasing temporary output files.
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        guard process.terminationStatus == 0 else {
            throw ProviderError.message("whisper-cli exited with status \(process.terminationStatus). Check the executable, model and available memory.")
        }
    }
}

enum KeychainService {
    private static let service = "com.justwisper.credentials"
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty { try delete(account: account); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProviderError.message("Could not save the API key to Keychain (\(status)).") }
    }
    static func load(account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ProviderError.message("Could not read the API key from Keychain (\(status)).")
        }
        return value
    }
    static func delete(account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProviderError.message("Could not remove the API key (\(status)).") }
    }
}
