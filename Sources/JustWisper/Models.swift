import Foundation

struct DictationMode: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var icon: String = "waveform"
    var instruction: String = ""
    var tone: Double?
    var language: String = "auto"
    var appBundleIDs: String = ""
    var speechConnectionID: UUID?
    var rewriteConnectionID: UUID?
    var speechModelOverride = ""
    var localModelOverride = ""
    var rewriteModelOverride = ""
    var siteDomains: String = ""
    var shortcut: HotKeySpec?
    var autoPaste: Bool = true
    static let defaults = [
        DictationMode(name: "Dictation", instruction: ""),
        DictationMode(name: "Clean", icon: "sparkles", instruction: "Clean up this dictation. Remove fillers and false starts, fix punctuation, and preserve meaning, language, names, and technical terms. Output only the cleaned text."),
        DictationMode(name: "Message", icon: "message", instruction: "Format the dictation as a clear, natural message. Remove filler words. Preserve intent and language. Output only the message.", tone: 0.5),
        DictationMode(name: "Email", icon: "envelope", instruction: "Format this dictation as a clear email. Preserve facts, names, intent, and language. Do not invent details. Output only the email.", tone: 0.75),
        DictationMode(name: "Notes", icon: "note.text", instruction: "Organize the dictation into concise notes with headings and bullet points. Preserve all substantive facts and original language. Output only the notes."),
        DictationMode(name: "Translate", icon: "character.bubble", instruction: "Translate the dictation to fluent English, preserving meaning, names and technical terms. Output only the translation.")
    ]
}
extension DictationMode {
    private enum CodingKeys: String, CodingKey { case id, name, icon, instruction, tone, language, appBundleIDs, siteDomains, shortcut, autoPaste, speechModelOverride, localModelOverride, rewriteModelOverride, speechConnectionID, rewriteConnectionID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        icon = try values.decodeIfPresent(String.self, forKey: .icon) ?? "waveform"
        instruction = try values.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        let decodedTone = try values.decodeIfPresent(Double.self, forKey: .tone)
        tone = decodedTone.map { $0.isFinite ? min(1, max(0, $0)) : 0.5 }
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        appBundleIDs = try values.decodeIfPresent(String.self, forKey: .appBundleIDs) ?? ""
        speechConnectionID = try values.decodeIfPresent(UUID.self, forKey: .speechConnectionID)
        rewriteConnectionID = try values.decodeIfPresent(UUID.self, forKey: .rewriteConnectionID)
        speechModelOverride = try values.decodeIfPresent(String.self, forKey: .speechModelOverride) ?? ""
        localModelOverride = try values.decodeIfPresent(String.self, forKey: .localModelOverride) ?? ""
        rewriteModelOverride = try values.decodeIfPresent(String.self, forKey: .rewriteModelOverride) ?? ""
        siteDomains = try values.decodeIfPresent(String.self, forKey: .siteDomains) ?? ""
        shortcut = try values.decodeIfPresent(HotKeySpec.self, forKey: .shortcut)
        autoPaste = try values.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
    }
}
struct VocabularyEntry: Identifiable, Codable {
    var id = UUID()
    var phrase: String
    var replacement: String = ""
}
struct Transcript: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var title: String
    var raw: String
    var text: String
    var mode: String
    var duration: Double
    var audioPath: String?
    var segments: [TranscriptionSegment]?
    var isMeeting = false
}
enum MeetingAudioSource: String, Codable, CaseIterable, Identifiable {
    case microphone, system, mixed
    var id: String { rawValue }
    var title: String { switch self { case .microphone: return "Microphone"; case .system: return "System audio"; case .mixed: return "Microphone + system audio" } }
}

struct AppSettings: Codable {
    var inputDeviceUID = ""
    var learnCorrections = false
    var autoSyncConfiguration = false
    var soundFeedback = false
    var duckOutput = false
    var appearance = "system"
    var fastOnDeviceDictation = false
    var fastDictationEngine = "local"
    var warmLocalWhisper = true
    var liveCaptions = false
    var liveCaptionEngine = "provider"
    var enableSpeakerSeparation = false
    var automationEnabled = false
    var configSyncFolder = ""
    var speechProvider = "local"
    var speechEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    var speechModel = "whisper-1"
    var localExecutable = ""
    var localModel = ""
    var rewriteEndpoint = "http://localhost:11434/v1/chat/completions"
    var rewriteModel = ""
    var language = "auto"
    var retainAudio = false
    var retentionDays = 30
    var autoPaste = true
    var showOverlay = true
    var launchAtLogin = false
    var cancelShortcut = HotKeySpec.cancel
    var toggleShortcut = HotKeySpec.toggle
    var holdShortcut = HotKeySpec.hold
    var workflowShortcut = HotKeySpec.workflow
    var modeSwitcherShortcut: HotKeySpec? = .modeSwitcher
    var mouseRecordingButton: Int?
    var mouseRecordingBehavior: MouseRecordingBehavior = .toggle
    var captureRecentClipboard = false
    var recordingOverlayStyle: RecordingOverlayStyle = .classic
    var effectiveRecordingOverlayStyle: RecordingOverlayStyle { showOverlay ? recordingOverlayStyle : .none }
    var captureFocusedText = false
    var captureSelectedText = false
    var meetingTemplate = "summary"
    var meetingSource: MeetingAudioSource = .mixed
    var meetingLiveTranslation = false
    var meetingTranslationCaptionEngine = "local"
    var meetingTranslationFrom = "en"
    var meetingTranslationTo = "de"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case meetingLiveTranslation, meetingTranslationCaptionEngine, meetingTranslationFrom, meetingTranslationTo
        case fastDictationEngine, warmLocalWhisper, fastOnDeviceDictation, speechProvider, speechEndpoint, speechModel, localExecutable, localModel, inputDeviceUID, liveCaptions, liveCaptionEngine, enableSpeakerSeparation, automationEnabled, configSyncFolder, appearance, soundFeedback, duckOutput, learnCorrections, autoSyncConfiguration
        case rewriteEndpoint, rewriteModel, language, retainAudio, retentionDays
        case cancelShortcut, workflowShortcut, autoPaste, showOverlay, modeSwitcherShortcut, mouseRecordingButton, mouseRecordingBehavior, captureRecentClipboard, recordingOverlayStyle, launchAtLogin, meetingSource, toggleShortcut, holdShortcut, captureFocusedText, captureSelectedText, meetingTemplate
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        meetingLiveTranslation = try values.decodeIfPresent(Bool.self, forKey: .meetingLiveTranslation) ?? false
        meetingTranslationCaptionEngine = try values.decodeIfPresent(String.self, forKey: .meetingTranslationCaptionEngine) ?? meetingTranslationCaptionEngine
        meetingTranslationFrom = try values.decodeIfPresent(String.self, forKey: .meetingTranslationFrom) ?? "en"
        meetingTranslationTo = try values.decodeIfPresent(String.self, forKey: .meetingTranslationTo) ?? "de"
        learnCorrections = try values.decodeIfPresent(Bool.self, forKey: .learnCorrections) ?? learnCorrections
        autoSyncConfiguration = try values.decodeIfPresent(Bool.self, forKey: .autoSyncConfiguration) ?? autoSyncConfiguration
        soundFeedback = try values.decodeIfPresent(Bool.self, forKey: .soundFeedback) ?? soundFeedback
        duckOutput = try values.decodeIfPresent(Bool.self, forKey: .duckOutput) ?? duckOutput
        appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        automationEnabled = try values.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? automationEnabled
        configSyncFolder = try values.decodeIfPresent(String.self, forKey: .configSyncFolder) ?? configSyncFolder
        inputDeviceUID = try values.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
        fastDictationEngine = try values.decodeIfPresent(String.self, forKey: .fastDictationEngine) ?? "local"
        warmLocalWhisper = try values.decodeIfPresent(Bool.self, forKey: .warmLocalWhisper) ?? true
        fastOnDeviceDictation = try values.decodeIfPresent(Bool.self, forKey: .fastOnDeviceDictation) ?? false
        liveCaptions = try values.decodeIfPresent(Bool.self, forKey: .liveCaptions) ?? liveCaptions
        liveCaptionEngine = try values.decodeIfPresent(String.self, forKey: .liveCaptionEngine) ?? liveCaptionEngine
        enableSpeakerSeparation = try values.decodeIfPresent(Bool.self, forKey: .enableSpeakerSeparation) ?? enableSpeakerSeparation
        speechProvider = try values.decodeIfPresent(String.self, forKey: .speechProvider) ?? speechProvider
        speechEndpoint = try values.decodeIfPresent(String.self, forKey: .speechEndpoint) ?? speechEndpoint
        speechModel = try values.decodeIfPresent(String.self, forKey: .speechModel) ?? speechModel
        localExecutable = try values.decodeIfPresent(String.self, forKey: .localExecutable) ?? localExecutable
        localModel = try values.decodeIfPresent(String.self, forKey: .localModel) ?? localModel
        rewriteEndpoint = try values.decodeIfPresent(String.self, forKey: .rewriteEndpoint) ?? rewriteEndpoint
        rewriteModel = try values.decodeIfPresent(String.self, forKey: .rewriteModel) ?? rewriteModel
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        retainAudio = try values.decodeIfPresent(Bool.self, forKey: .retainAudio) ?? retainAudio
        retentionDays = max(0, try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? retentionDays)
        autoPaste = try values.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? autoPaste
        showOverlay = try values.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? showOverlay
        recordingOverlayStyle = try values.decodeIfPresent(RecordingOverlayStyle.self, forKey: .recordingOverlayStyle) ?? (showOverlay ? .classic : .none)
        // Existing libraries do not gain a new global key without an explicit choice;
        // omission also persists a disabled optional shortcut.
        modeSwitcherShortcut = try values.decodeIfPresent(HotKeySpec.self, forKey: .modeSwitcherShortcut)
        let mouseButton = try values.decodeIfPresent(Int.self, forKey: .mouseRecordingButton)
        mouseRecordingButton = mouseButton.flatMap { [2, 3, 4].contains($0) ? $0 : nil }
        mouseRecordingBehavior = try values.decodeIfPresent(MouseRecordingBehavior.self, forKey: .mouseRecordingBehavior) ?? mouseRecordingBehavior
        captureRecentClipboard = try values.decodeIfPresent(Bool.self, forKey: .captureRecentClipboard) ?? captureRecentClipboard
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        cancelShortcut = try values.decodeIfPresent(HotKeySpec.self, forKey: .cancelShortcut) ?? cancelShortcut
        toggleShortcut = try values.decodeIfPresent(HotKeySpec.self, forKey: .toggleShortcut) ?? toggleShortcut
        workflowShortcut = try values.decodeIfPresent(HotKeySpec.self, forKey: .workflowShortcut) ?? workflowShortcut
        holdShortcut = try values.decodeIfPresent(HotKeySpec.self, forKey: .holdShortcut) ?? holdShortcut
        captureFocusedText = try values.decodeIfPresent(Bool.self, forKey: .captureFocusedText) ?? captureFocusedText
        captureSelectedText = try values.decodeIfPresent(Bool.self, forKey: .captureSelectedText) ?? captureSelectedText
        meetingTemplate = try values.decodeIfPresent(String.self, forKey: .meetingTemplate) ?? meetingTemplate
        meetingSource = try values.decodeIfPresent(MeetingAudioSource.self, forKey: .meetingSource) ?? meetingSource
    }

    mutating func detectLocalInstallation(resourceURL: URL? = Bundle.main.resourceURL, workspaceURL: URL? = nil) {
        let manager = FileManager.default
        if localExecutable.isEmpty {
            let candidates = [resourceURL?.appendingPathComponent("bin/whisper-cli").path, "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].compactMap { $0 }
            localExecutable = candidates.first { manager.isExecutableFile(atPath: $0) } ?? ""
        }
        if localModel.isEmpty {
            var workspace = workspaceURL
            #if DEBUG
            workspace = workspace ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            #endif
            let candidates = [resourceURL?.appendingPathComponent("Models/ggml-medium.bin"), workspace?.appendingPathComponent("Models/ggml-medium.bin")].compactMap { $0 }
            localModel = candidates.first { manager.isReadableFile(atPath: $0.path) }?.path ?? ""
        }
    }
}
struct LibraryState: Codable {
    var modes = DictationMode.defaults
    var vocabulary: [VocabularyEntry] = []
    var snippets: [TextSnippet] = []
    var connections: [ProviderConnection] = []
    var workflows: [VoiceWorkflow] = []
    var history: [Transcript] = []
    var settings = AppSettings()
    var selectedModeID: UUID?
}

extension LibraryState {
    private enum CodingKeys: String, CodingKey { case modes, vocabulary, snippets, connections, workflows, history, settings, selectedModeID }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workflows = try values.decodeIfPresent([VoiceWorkflow].self, forKey: .workflows) ?? []
        modes = try values.decodeIfPresent([DictationMode].self, forKey: .modes) ?? modes
        vocabulary = try values.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? vocabulary
        connections = try values.decodeIfPresent([ProviderConnection].self, forKey: .connections) ?? connections
        snippets = try values.decodeIfPresent([TextSnippet].self, forKey: .snippets) ?? snippets
        history = try values.decodeIfPresent([Transcript].self, forKey: .history) ?? history
        settings = try values.decodeIfPresent(AppSettings.self, forKey: .settings) ?? settings
        selectedModeID = try values.decodeIfPresent(UUID.self, forKey: .selectedModeID)
    }
}

enum TextProcessing {
    static func replaceVocabulary(_ text: String, entries: [VocabularyEntry]) -> String {
        let replacements = entries.filter { !$0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.replacement.isEmpty }
            .sorted { $0.phrase.count > $1.phrase.count }
        guard !replacements.isEmpty else { return text }
        let alternatives = replacements.map { NSRegularExpression.escapedPattern(for: $0.phrase) }.joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let entry = replacements.first(where: { $0.phrase.caseInsensitiveCompare(String(text[range])) == .orderedSame }),
                  let resultRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(resultRange, with: entry.replacement)
        }
        return result
    }
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let tokenize: (String) -> [String] = { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let a = tokenize(reference), b = tokenize(hypothesis)
        if a.isEmpty { return b.isEmpty ? 0 : 1 }
        var row = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for j in b.indices { next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (word == b[j] ? 0 : 1)) }
            row = next
        }
        return Double(row[b.count]) / Double(a.count)
    }
}
