import Foundation
import Testing
@testable import JustWisper

struct LocalWhisperLiveTests {
    @Test func startupResamplingDriftDoesNotCommitOpeningWordsRepeatedly() throws {
        var accumulator = LocalWhisperAccumulator()
        let words: [LocalWhisperWord] = [
            .init(start: 0, end: 0.4, text: "first"),
            .init(start: 0.4, end: 0.8, text: "few"),
            .init(start: 0.8, end: 1.2, text: "words")
        ]
        for index in 0..<5 {
            accumulator.update(words, start: Double(index) / 16000, end: 2 + Double(index))
            #expect(accumulator.text == "first few words")
            #expect(accumulator.committed.isEmpty)
        }
        #expect(try accumulator.finalText(at: 6) == "first few words")
    }

    @Test func repeatedFinalWindowDoesNotRestoreCommittedPrefixOrEraseRealRepetition() throws {
        var accumulator = LocalWhisperAccumulator()
        accumulator.update([.init(start: 0, end: 1, text: "go"), .init(start: 1, end: 2, text: "go")], start: 0, end: 3)
        let tail: [LocalWhisperWord] = [.init(start: 0, end: 1, text: "go"), .init(start: 1, end: 2, text: "now")]
        accumulator.update(tail, start: 1, end: 4)
        #expect(try accumulator.finalText(at: 4) == "go go now")
        accumulator.update(tail, start: 1, end: 4)
        #expect(try accumulator.finalText(at: 4) == "go go now")
    }

    @Test func timestampDriftDoesNotRestoreCommittedBoundaryWord() {
        var accumulator = LocalWhisperAccumulator()
        accumulator.update([.init(start: 0.4, end: 1, text: "heute")], start: 0, end: 3)
        accumulator.update([.init(start: 0, end: 0.5, text: "geht")], start: 1, end: 4)
        accumulator.update([
            .init(start: 0, end: 0.35, text: "heute"),
            .init(start: 0.35, end: 0.75, text: "geht")
        ], start: 0.9, end: 4)
        #expect(accumulator.text == "heute geht")
    }

    @Test func quietSpeechGainIsBoundedAndLeavesSilenceAndLoudAudioAlone() {
        var quiet: [Float] = [0, 0.01, -0.02]
        var silence: [Float] = [0, 0, 0]
        var loud: [Float] = [0, 0.7, -0.9]
        quiet.withUnsafeMutableBufferPointer { QuietSpeechGain.apply(to: $0) }
        silence.withUnsafeMutableBufferPointer { QuietSpeechGain.apply(to: $0) }
        loud.withUnsafeMutableBufferPointer { QuietSpeechGain.apply(to: $0) }
        #expect(quiet == [0, 0.04, -0.08])
        #expect(silence == [0, 0, 0])
        #expect(loud == [0, 0.7, -0.9])
    }

    @Test func overlappingWindowsReplaceHypothesesAndNeverRepeatWholeWindows() throws {
        var accumulator = LocalWhisperAccumulator()
        accumulator.update([.init(start: 0, end: 1, text: "hello"), .init(start: 1, end: 2, text: "wrong")], start: 0, end: 3)
        accumulator.update([.init(start: 0, end: 1, text: "hello"), .init(start: 1, end: 2, text: "world")], start: 0, end: 4)
        #expect(accumulator.text == "hello world")
        accumulator.update([.init(start: 0, end: 1, text: "world"), .init(start: 1, end: 2, text: "today")], start: 1, end: 5)
        #expect(accumulator.text == "hello world today")
        #expect(try accumulator.finalText(at: 5) == "hello world today")
    }
    @Test func missingCoverageAndTruncatedTailNeverBecomeFinal() {
        var gap = LocalWhisperAccumulator()
        gap.update([.init(start: 0, end: 1, text: "later words")], start: 10, end: 12)
        #expect(!gap.complete)
        #expect(throws: (any Error).self) { try gap.finalText(at: 12) }
        var incomplete = LocalWhisperAccumulator()
        incomplete.update([.init(start: 0, end: 1, text: "first")], start: 0, end: 2)
        #expect(throws: (any Error).self) { try incomplete.finalText(at: 3) }
    }
    @Test func longSessionsBoundPreviewAndRequireFullAudioRecoveryWhenTruncated() {
        var accumulator = LocalWhisperAccumulator()
        for index in 0..<4000 {
            let start = Double(index)
            accumulator.update([.init(start: 0, end: 0.5, text: String(repeating: "x", count: 25))], start: start, end: start + 1)
        }
        #expect(accumulator.truncated)
        #expect(accumulator.committed.count <= 3000)
        #expect(accumulator.text.utf8.count < 45_000)
        #expect(throws: (any Error).self) { try accumulator.finalText(at: 4000) }
    }
    @Test func emptyAndSilenceNeverInventWords() {
        var accumulator = LocalWhisperAccumulator()
        accumulator.update([], start: 0, end: 5)
        #expect(accumulator.text.isEmpty)
        #expect(throws: NoSpeechDetected.self) { try accumulator.finalText(at: 5) }
    }
    @Test func publicRepeatedJFKWindowsDoNotAppendDuplicateHypotheses() throws {
        struct Fixture: Decodable {
            struct Window: Decodable { var start: Double; var end: Double; var segments: [LocalWhisperWord] }
            var warm_windows: [Window]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("benchmarks/results/live-jfk-base.json")))
        var accumulator = LocalWhisperAccumulator()
        for window in fixture.warm_windows { accumulator.update(window.segments, start: window.start, end: window.end) }
        let reference = Array(repeating: "And so my fellow Americans ask not what your country can do for you ask what you can do for your country", count: 4).joined(separator: " ")
        let wer = TextProcessing.wordErrorRate(reference: reference, hypothesis: accumulator.text)
        #expect(wer <= 0.15)
        #expect(accumulator.text.split(separator: " ").count < 110)
    }
    @Test @MainActor func residentModelReusedAcrossSessionsAndReloadedOnModelChange() async throws {
        var workers: [FakeResidentWhisper] = []
        let service = LocalWhisperLiveService(makeWorker: { _, _, _ in
            let worker = FakeResidentWhisper(); workers.append(worker); return worker
        }, runtime: { _ in URL(fileURLWithPath: "/fake-helper") })
        try await service.warm(model: "/model-a", language: "en")
        service.stopSession()
        try await service.warm(model: "/model-a", language: "en")
        #expect(workers.count == 1)
        #expect(workers[0].readyCalls == 1)
        #expect(service.isReady)
        try await service.warm(model: "/model-b", language: "en")
        #expect(workers.count == 2)
        #expect(workers[0].terminated)
        service.release()
        #expect(workers[1].terminated)
        #expect(!service.isReady)
    }
    @Test func localLiveDefaultsDoNotRequireAppleOrEnableCloud() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.fastDictationEngine == "local")
        #expect(settings.warmLocalWhisper)
        #expect(settings.speechProvider == "local")
        #expect(!LocalWhisperRuntime.available(model: "/no-such-ggml-model"))
    }
}

private final class FakeResidentWhisper: ResidentWhisperServing, @unchecked Sendable {
    var readyCalls = 0
    var terminated = false
    func ready() async throws -> LocalWhisperReply {
        readyCalls += 1
        return LocalWhisperReply(ready: true, protocol: 1, segments: nil, silent: nil)
    }
    func infer(_ samples: [Float]) async throws -> LocalWhisperReply { LocalWhisperReply(ready: nil, protocol: nil, segments: [], silent: true) }
    func terminate() { terminated = true }
}
