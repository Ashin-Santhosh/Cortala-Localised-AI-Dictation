import Foundation
import Testing
@testable import JustWisper

struct MeetingTranslationLifecycleTests {
    @Test(arguments: [LiveMeetingTranslation.Engine.languageModel, .ollama])
    @MainActor func modelDoesNotWarmUntilMeetingAndStopsPublishingAfterStop(engine: LiveMeetingTranslation.Engine) async throws {
        let service = LiveMeetingTranslation(engine: engine)
        var calls: [String] = []
        try service.prepareLanguageModel(source: "en", target: "de", endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!, model: "fixture", key: "", translate: { text in
            calls.append(text)
            if text != "Ready." { service.pauseCapture() }
            return "late result"
        })
        #expect(calls.isEmpty)
        try service.beginCapture(settings: engine == .ollama ? AppSettings() : nil)
        service.receive("Hello world")
        for _ in 0..<100 where calls.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == ["Ready.", "Hello world"])
        #expect(service.translated.isEmpty)
        #expect(service.sessionID == nil)
        service.reset()
    }
    @Test @MainActor func installedAppleAssetsDoNotKeepSessionActive() async throws {
        let service = LiveMeetingTranslation(engine: .apple)
        service.prepare(source: "en", target: "de")
        let id = try #require(service.sessionID)
        await service.run(id: id, releaseAfterPrepare: true, prepare: {}, translate: { _ in Issue.record("No meeting: translation must not run"); return "" })
        #expect(service.ready)
        #expect(service.sessionID == nil)
        try service.beginCapture()
        #expect(service.sessionID != nil)
        service.pauseCapture()
        #expect(service.sessionID == nil)
    }
    @Test @MainActor func meetingWithoutCaptionsLeavesPreparedLanguagesReadyForNextRecording() async throws {
        let service = LiveMeetingTranslation(engine: .apple)
        service.prepare(source: "en", target: "de")
        let id = try #require(service.sessionID)
        await service.run(id: id, releaseAfterPrepare: true, prepare: {}, translate: { _ in "" })

        service.skipCapture(reason: "Speech Recognition permission is required.")
        #expect(!service.isCapturing)
        #expect(service.error?.contains("Speech Recognition") == true)
        #expect(service.isPrepared(source: "en", target: "de"))

        try service.beginCapture()
        #expect(service.isCapturing)
        #expect(service.error == nil)
        service.pauseCapture()
    }

    @Test @MainActor func changedProviderRequiresExplicitPreparation() throws {
        let service = LiveMeetingTranslation(engine: .languageModel)
        try service.prepareLanguageModel(source: "en", target: "de", endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!, model: "fixture", key: "", translate: { _ in "" })
        var settings = AppSettings()
        settings.rewriteModel = "different-model"
        #expect(throws: (any Error).self) { try service.beginCapture(settings: settings) }
        #expect(!service.ready)
    }
}
