import Foundation
import Testing
import Translation
@testable import JustWisper

struct LiveMeetingTranslationTests {
    @Test func legacySettingsKeepTranslationOptIn() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!old.meetingLiveTranslation)
        var settings = old
        settings.meetingLiveTranslation = true; settings.meetingTranslationFrom = "fr"; settings.meetingTranslationTo = "ja"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.meetingLiveTranslation && restored.meetingTranslationFrom == "fr" && restored.meetingTranslationTo == "ja")
    }
    @Test func queueCoalescesUpdatesAndBoundsWork() {
        var queue = TranslationCaptionQueue()
        let now = Date()
        queue.receive("First phrase")
        let first = queue.take(now: now)
        #expect(first == "First phrase")
        queue.receive("Second phrase"); queue.receive("Latest phrase")
        let early = queue.take(now: now.addingTimeInterval(0.2))
        #expect(early == nil)
        let latest = queue.take(now: now.addingTimeInterval(1))
        #expect(latest == "Latest phrase")
        let duplicate = queue.take(now: now.addingTimeInterval(2))
        #expect(duplicate == nil)
        queue.receive(String(repeating: "long words ", count: 1000))
        #expect(queue.latest.count <= 480)
    }
    @Test func growingCaptionDoesNotRetranslateCompletedSentences() {
        var queue = TranslationCaptionQueue()
        let now = Date()
        queue.receive("Das Meeting beginnt. Wir besprechen den Plan.")
        #expect(queue.take(now: now, minimumInterval: 0.3) == "Wir besprechen den Plan.")
        queue.receive("Das Meeting beginnt. Wir besprechen den Plan. Danach folgen Fragen.")
        #expect(queue.take(now: now.addingTimeInterval(0.35), minimumInterval: 0.3) == "Danach folgen Fragen.")
    }
    @Test @MainActor func oldSessionCannotPublishAfterLanguageChange() async throws {
        let service = LiveMeetingTranslation(engine: .apple)
        service.prepare(source: "en", target: "de")
        let id = try #require(service.sessionID)
        let task = Task { await service.run(id: id, prepare: {}, translate: { _ in
            service.prepare(source: "en", target: "fr")
            return "old result"
        }) }
        for _ in 0..<100 where !service.ready { try await Task.sleep(nanoseconds: 1_000_000) }
        try service.beginCapture(); service.receive("Hello")
        await task.value
        #expect(service.translated.isEmpty)
        #expect(!service.ready)
        #expect(service.target == "fr")
    }
    @Test @MainActor func translationFailureIsVisibleWithoutInventingCaptions() async throws {
        let service = LiveMeetingTranslation(engine: .apple)
        service.prepare(source: "en", target: "de")
        let id = try #require(service.sessionID)
        let task = Task { await service.run(id: id, prepare: {}, translate: { _ in throw AppError.message("translation unavailable") }) }
        for _ in 0..<100 where !service.ready { try await Task.sleep(nanoseconds: 1_000_000) }
        try service.beginCapture(); service.receive("Hello")
        await task.value
        #expect(service.translated.isEmpty)
        #expect(!service.ready)
        #expect(service.error == "translation unavailable")
    }
    @Test @MainActor func stoppedCaptureRejectsLateTranslatedText() async throws {
        let service = LiveMeetingTranslation(engine: .apple)
        service.prepare(source: "en", target: "de")
        let id = try #require(service.sessionID)
        let task = Task { await service.run(id: id, prepare: {}, translate: { _ in
            service.pauseCapture()
            return "late result"
        }) }
        for _ in 0..<100 where !service.ready { try await Task.sleep(nanoseconds: 1_000_000) }
        try service.beginCapture(); service.receive("Hello")
        try await Task.sleep(nanoseconds: 150_000_000)
        service.reset(); task.cancel(); await task.value
        #expect(service.translated.isEmpty)
    }
    @Test func installedAppleTranslationSmoke() async throws {
        guard ProcessInfo.processInfo.environment["JUSTWISPER_TRANSLATION_SMOKE"] == "1" else { return }
        guard #available(macOS 26.0, *) else { return }
        let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "de")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            print("TRANSLATION_SMOKE_NEEDS_LANGUAGE_DOWNLOAD: English and German are not installed. Use Prepare languages in Meetings.")
            return
        }
        let session = TranslationSession(installedSource: source, target: target)
        let started = Date()
        for _ in 0..<20 {
            let result = try await session.translate("Tomorrow we will review the project updates and agree on the next steps.")
            #expect(!result.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        print("TRANSLATION_SMOKE_20_CHUNKS_SECONDS=\(Date().timeIntervalSince(started))")
    }
}
