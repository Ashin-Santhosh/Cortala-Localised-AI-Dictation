import SwiftUI
import AppKit
import Carbon

@main struct JustWisperApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var store: AppStore
    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        lifecycle.configure(store: store)
    }
    var body: some Scene {
        WindowGroup("Cortala", id: "main") {
            MainView().environmentObject(store).frame(minWidth: 920, minHeight: 650)
                .background {
                    if #available(macOS 15.0, *) { MeetingTranslationHost(service: store.meetingTranslation) }
                }
                .onOpenURL { url in
                    if url.isFileURL {
                        store.requestIncomingImport(url)
                        return
                    }
                    guard url.scheme?.lowercased() == "justwisper" else { return }
                    store.executeCommandURL(url)
                }
        }.defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) { Button("Import audio or video…") { store.importAudio() }.keyboardShortcut("o").disabled(store.busy) }
            CommandMenu("Dictation") {
                Button(store.isRecording ? "Stop recording" : "Start recording") { store.toggleRecording() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(store.isStarting || store.isProcessing)
                Button("Cancel") { store.cancel() }
            }
            CommandGroup(replacing: .help) { Button("Cortala Help & Tutorial") { store.page = .help } }
        }
        MenuBarExtra("Cortala", systemImage: store.isRecording ? "mic.fill" : "waveform") {
            MenuContents().environmentObject(store)
        }
    }
}
struct MenuContents: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(store.status)
        Button(store.isRecording ? "Stop recording" : "Start recording") { store.toggleRecording() }.disabled(store.isStarting || store.isProcessing)
        Button("Mode switcher…") { store.showModeSwitcher() }.disabled(store.busy)
        Menu("Mode") { ForEach(store.library.modes) { mode in Button(mode.name) { _ = store.chooseMode(mode.id) } } }.disabled(store.busy)
        Button("Transform selection with current mode") { store.transformSelection() }.disabled(store.busy || !store.library.settings.captureSelectedText)
        Button("Copy latest transcript") { store.desktop.copy(store.latestText) }.disabled(store.latestText.isEmpty)
        Divider()
        Button("Open Cortala") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
enum SidebarPage: String, CaseIterable, Identifiable {
    case workflows = "Workflows", home = "Home", meetings = "Meetings", sound = "Sound", snippets = "Snippets", modes = "Modes", vocabulary = "Vocabulary", configuration = "Configuration", models = "Models library", accuracy = "Accuracy lab", help = "Help & Tutorial", errors = "Errors"
    var id: Self { self }
    var icon: String { switch self { case .errors: return "exclamationmark.bubble"; case .workflows: return "list.bullet.rectangle"; case .help: return "questionmark.circle"; case .sound: return "speaker.wave.2"; case .snippets: return "text.badge.plus"; case .home: return "house"; case .meetings: return "person.2"; case .modes: return "sparkles"; case .vocabulary: return "book.closed"; case .configuration: return "slider.horizontal.3"; case .models: return "cpu"; case .accuracy: return "chart.bar.xaxis" } }
}
struct MainView: View {
    @EnvironmentObject var store: AppStore
    private var formattingRoute: String {
        let mode = store.selectedMode
        guard !mode.processingInstruction.isEmpty else { return "Formatting off · raw text" }
        let connection = store.library.connections.first { $0.id == mode.rewriteConnectionID && $0.kind == "rewrite" }
        if mode.rewriteConnectionID != nil && connection == nil { return "Formatting · connection missing" }
        let model = mode.rewriteModelOverride.isEmpty ? (connection?.model ?? store.library.settings.rewriteModel) : mode.rewriteModelOverride
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Formatting off · raw text" }
        let host = URL(string: connection?.endpoint ?? store.library.settings.rewriteEndpoint)?.host?.lowercased() ?? ""
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) ? "Formatting · local server" : "Formatting · remote endpoint"
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) { Image(systemName: "waveform").font(.title).foregroundStyle(.mint); Text("Cortala").font(.title2.weight(.semibold)) }.padding(.vertical, 26).padding(.horizontal, 16)
                ForEach(SidebarPage.allCases) { page in
                    Button { store.page = page } label: {
                        HStack(spacing: 13) { Image(systemName: page.icon).frame(width: 22); Text(page.rawValue); Spacer(); if page == .errors && !store.errorEvents.isEmpty { Text("\(store.errorEvents.count)").font(.caption).foregroundStyle(.orange) } }.padding(12)
                            .background(store.page == page ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).font(.system(size: 14, weight: store.page == page ? .semibold : .regular))
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label(store.selectedMode.speechConnectionID == nil && store.library.settings.speechProvider == "local" ? "On-device transcription" : "API transcription", systemImage: store.selectedMode.speechConnectionID == nil && store.library.settings.speechProvider == "local" ? "lock.shield" : "cloud").font(.caption)
                    Text(formattingRoute).font(.caption).foregroundStyle(.secondary)
                    Text("DEVELOPMENT BUILD  ·  0.2").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
                }.padding(16)
            }.padding(.horizontal, 10).frame(width: 220).background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(store.page.rawValue).font(.system(size: 27, weight: .semibold)); Spacer(); HStack(spacing: 6) { Circle().fill(store.isRecording ? .red : .mint).frame(width: 6, height: 6); Text(store.status).font(.caption).foregroundStyle(.secondary) } }.padding(28)
                ScrollView { Group {
                    switch store.page {
                    case .workflows: WorkflowsView()
                    case .home: HomeView()
                    case .meetings: MeetingsView()
                    case .modes: ModesView()
                    case .vocabulary: VocabularyView()
                    case .snippets: SnippetsView()
                    case .sound: SoundSettingsView()
                    case .configuration: ConfigurationView()
                    case .models: ModelsView()
                    case .accuracy: AccuracyView()
                    case .help: HelpTutorialView()
                    case .errors: ErrorLogView()
                    }
                }.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading) }
            }.background(Color(nsColor: .underPageBackgroundColor))
        }.preferredColorScheme(store.library.settings.appearance == "dark" ? .dark : store.library.settings.appearance == "light" ? .light : nil).tint(.mint)
        .sheet(item: $store.pendingWorkflow) { workflow in
            VStack(alignment: .leading, spacing: 16) {
                Text("Run \(workflow.name)?").font(.title2)
                Text("These actions will run in order. Opened apps or pages remain open if you stop.")
                ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(Array(workflow.actions.enumerated()), id: \.element.id) { index, action in Text("\(index + 1). \(action.summary)").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 350)
                HStack { Button("Cancel") { store.pendingWorkflow = nil }; Button("Run these actions") { store.approveWorkflow() }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 580)
        }
        .sheet(isPresented: $store.showingWelcome, onDismiss: { store.completeWelcome() }) { WelcomeGuideView().environmentObject(store) }
        .confirmationDialog("Allow this external app command?", isPresented: Binding(get: { store.pendingExternalCommand != nil }, set: { if !$0 { store.dismissExternalCommand() } }), titleVisibility: .visible) {
            Button("Allow this action once") { store.approveExternalCommand() }
            Button("Cancel", role: .cancel) { store.dismissExternalCommand() }
        } message: {
            Text("\(store.pendingExternalCommand?.userFacingAction ?? "An external link requested an action.") Recording and transcription use your current provider settings. Approve only an action you requested.")
        }
        .confirmationDialog("Transcribe this incoming recording?", isPresented: Binding(get: { store.pendingImportURL != nil }, set: { if !$0 { store.dismissIncomingImport() } }), titleVisibility: .visible) {
            Button("Transcribe recording") { store.approveIncomingImport() }
            Button("Cancel", role: .cancel) { store.dismissIncomingImport() }
        } message: {
            Text("\(store.pendingImportURL?.lastPathComponent ?? "Recording") will use your selected speech provider and optional text-formatting provider. Cloud providers receive the submitted audio or text.")
        }
    }
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 16) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07))) }
}
struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var canAutoPaste = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Panel {
                HStack {
                    VStack(alignment: .leading, spacing: 7) { Text(store.isRecording ? "Listening to you…" : "Turn a thought into words.").font(.title2.weight(.semibold)); Text("Use a global shortcut in a text field, or record here to review and copy.").foregroundStyle(.secondary) }
                    Spacer(); Image(systemName: "waveform").font(.system(size: 38)).foregroundStyle(.mint)
                }
                DictationSpeedPicker()
                HStack(alignment: .top, spacing: 12) {
                    Label {
                        Text(canAutoPaste ? "Accessibility allowed" : "Accessibility required for auto-paste")
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(canAutoPaste ? .green : .red)
                    }
                    if !canAutoPaste {
                        Button("Open Accessibility settings") { SetupDestination.open("Accessibility") }
                    }
                }
                .task { canAutoPaste = store.desktop.canAutoPaste }
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                    canAutoPaste = store.desktop.canAutoPaste
                }
                HStack {
                    Picker("Mode", selection: Binding(get: { store.selectedMode.id }, set: { _ = store.chooseMode($0) })) { ForEach(store.library.modes) { Text($0.name).tag($0.id) } }.frame(maxWidth: 270).disabled(store.busy)
                    Spacer()
                    if store.isRecording { Text(Duration.seconds(store.recordingSeconds).formatted(.time(pattern: .minuteSecond))).monospacedDigit() }
                    Button { store.toggleRecording() } label: { Label(store.isStarting ? "Preparing…" : (store.isRecording ? "Stop recording" : "Start recording"), systemImage: store.isRecording ? "stop.fill" : "mic.fill").padding(.vertical, 6) }.buttonStyle(.borderedProminent).disabled(store.isStarting || store.isProcessing)
                    if store.busy { Button("Cancel") { store.cancel() } }
                }
                Text("For the shortest delay, choose a mode with empty processing instructions, such as Dictation. Formatting modes can add a language-model step after speech recognition.").font(.caption).foregroundStyle(.secondary)
                HStack { Text("\(store.library.settings.toggleShortcut.displayName) to toggle  ·  \(store.library.settings.holdShortcut.displayName) to hold").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Import audio or video…") { store.importAudio() }.disabled(store.busy) }
                if let shortcutError = store.desktop.hotKeyError {
                    Label(shortcutError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            if store.isRecording && (store.library.settings.liveCaptions || store.fastDictationActive) {
                ProvisionalCaptionsView()
            }
            if !store.latestText.isEmpty { Panel { HStack { Text("Latest transcript").font(.headline); Spacer(); Button("Copy") { store.desktop.copy(store.latestText) } }; Text(store.latestText).textSelection(.enabled) } }
            StatisticsView()
            HStack { Text("History").font(.title3.weight(.semibold)); Spacer(); TextField("Search transcripts", text: $search).textFieldStyle(.roundedBorder).frame(width: 240) }
            let entries = store.library.history.filter { !$0.isMeeting && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.raw.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search)) }
            if entries.isEmpty { EmptyCard(icon: "text.alignleft", title: "A little quieter here", subtitle: "Your transcripts will appear here after your first recording.") }
            ForEach(entries) { TranscriptCard(entry: $0) }
        }
    }
}
struct DictationSpeedPicker: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Dictation speed", selection: Binding(get: { store.library.settings.fastOnDeviceDictation }, set: { store.library.settings.fastOnDeviceDictation = $0; store.save() })) {
                Text("Accurate · selected model").tag(false)
                Text("Live · on-device").tag(true)
            }.pickerStyle(.segmented).disabled(store.busy)
            if store.library.settings.fastOnDeviceDictation {
                Picker("Live speech engine", selection: Binding(get: { store.library.settings.fastDictationEngine }, set: { store.library.settings.fastDictationEngine = $0; store.save() })) {
                    Text("Local Whisper · selected GGML model").tag("local")
                    Text("Apple Speech · optional").tag("apple")
                }.disabled(store.busy)
            }
            Text(store.library.settings.fastOnDeviceDictation
                 ? (store.library.settings.fastDictationEngine == "local" ? "Local Whisper keeps your selected GGML model resident and revises overlapping audio windows as you speak. Stop decodes the final tail; gaps or incomplete recognition recover from the saved audio locally. No Apple Speech permission or cloud audio upload is used." : "Apple Speech is optional and needs Speech Recognition permission. Stop awaits its final words; incomplete recognition can recover with your selected local Whisper model.")
                 : "Stop sends the complete recording to your selected local or cloud speech model. Live shows provisional words while you speak.").font(.caption).foregroundStyle(.secondary)
            if store.library.settings.fastDictationEngine == "local" {
                Toggle("Warm local Whisper at launch and keep model in memory", isOn: Binding(get: { store.library.settings.warmLocalWhisper }, set: { store.library.settings.warmLocalWhisper = $0; store.save() })).disabled(store.busy)
                HStack {
                    Text(store.localWhisper.state).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Warm now") { store.refreshLocalWhisperWarmth(ignorePreference: true) }.disabled(store.busy)
                    Button("Release memory") { store.releaseLocalWhisper() }.disabled(store.busy)
                }
                if let load = store.localWhisper.loadSeconds { Text("Model load: \(load, specifier: "%.2f") s · latest window: \(store.localWhisper.inferenceSeconds ?? 0, specifier: "%.2f") s").font(.caption).foregroundStyle(.secondary) }
            }
            Text("This choice applies to new dictation recordings. Meetings and imported files use the selected speech model.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct ProvisionalCaptionsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Panel {
            Text(store.fastDictationActive ? "Live dictation · provisional words" : "Provisional captions · recent audio").font(.headline)
            Text(store.provisionalText.isEmpty ? "Waiting for speech…" : store.provisionalText).textSelection(.enabled)
            Text(store.localWhisperActive ? "Local Whisper revises recent speech on this Mac. Words can change until Stop; the final audio tail is decoded locally, with full saved-audio recovery if needed. Long sessions show only recent provisional text. No provisional words are pasted." : store.fastDictationActive ? "Apple Speech updates words on this Mac as you speak. Stop finalizes this on-device transcript, then applies any configured formatting for your mode. Live words can change and are never pasted while recording." : (store.library.settings.meetingLiveTranslation && store.page == .meetings ?
                store.library.settings.meetingTranslationCaptionEngine : store.library.settings.liveCaptionEngine) == "apple" ? "Apple Speech updates incremental hypotheses on this Mac. Microphone/System audio labels identify inputs, not people. Final transcription uses your selected full-recording model after Stop. Captions are never pasted." : "A rolling audio window refreshes about every six seconds. Final transcription uses the full recording after Stop. Previews are never pasted.").font(.caption).foregroundStyle(.secondary)
            if let warning = store.provisionalWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
        }
    }
}
struct EmptyCard: View {
    var icon: String; var title: String; var subtitle: String
    var body: some View { VStack(spacing: 12) { Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary); Text(title).font(.headline); Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(48) }
}
struct TranscriptCard: View {
    @EnvironmentObject var store: AppStore
    let entry: Transcript
    @State private var expanded = false
    @State private var confirmDelete = false
    @State private var confirmRetry = false
    @State private var question = ""
    @State private var editing = false
    private var hasAudio: Bool { entry.audioPath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false }
    var body: some View {
        Panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.headline).lineLimit(1)
                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened))  ·  \(entry.mode)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.help(expanded ? "Collapse transcript" : "Expand transcript")
                Button { store.desktop.copy(entry.text) } label: { Image(systemName: "doc.on.doc") }.help("Copy transcript").disabled(entry.text.isEmpty)
                Button { store.export(entry) } label: { Image(systemName: "square.and.arrow.up") }.help("Export transcript").disabled(entry.text.isEmpty)
                Menu {
                    Button("Edit transcript…") { editing = true }.disabled(entry.text.isEmpty)
                    Button("Apply selected mode to saved transcript") { store.reformat(entry) }.disabled(entry.raw.isEmpty)
                    Button("Delete transcript…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().disabled(store.busy)
            }
            if entry.text.isEmpty {
                Label("Audio saved · awaiting transcription", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            } else {
                Text(entry.text).lineLimit(expanded ? nil : 3).textSelection(.enabled).foregroundStyle(.secondary)
            }
            if expanded && !entry.raw.isEmpty && entry.raw != entry.text {
                DisclosureGroup("Original transcript") { Text(entry.raw).textSelection(.enabled).padding(.top, 8) }
            }
            if expanded && !(entry.segments ?? []).isEmpty {
                DisclosureGroup("Timestamped transcript") {
                    ForEach(Array((entry.segments ?? []).enumerated()), id: \.offset) { _, segment in
                        HStack(alignment: .top) { Text(Duration.seconds(segment.start).formatted(.time(pattern: .minuteSecond))).monospacedDigit().foregroundStyle(.secondary); Text((segment.speaker.map { $0 + ": " } ?? "") + segment.text).textSelection(.enabled) }.font(.callout)
                    }
                }
            }
            if expanded && entry.isMeeting && !entry.raw.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("Ask this meeting a question", text: $question); Button("Ask") { store.askMeeting(entry, question: question) }.disabled(store.busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    Text("Uses the selected mode's language connection, original transcript and available timestamped speaker segments. Speaker numbers are anonymous; check supporting quotations before acting on an answer.").font(.caption).foregroundStyle(.secondary)
                    if let answer = store.meetingAnswers[entry.id] { Text(answer).textSelection(.enabled); Button("Copy answer") { store.desktop.copy(answer) } }
                    Button("Regenerate notes with selected template") { store.reformat(entry) }.disabled(store.busy)
                }
            }
            if hasAudio {
                HStack {
                    Button {
                        if store.playingTranscriptID == entry.id { store.stopPlayback() } else { store.replayAudio(entry) }
                    } label: { Label(store.playingTranscriptID == entry.id ? "Stop playback" : "Play audio", systemImage: store.playingTranscriptID == entry.id ? "stop.fill" : "play.fill") }
                    Button(entry.raw.isEmpty ? "Retry transcription" : "Transcribe again…") {
                        if entry.raw.isEmpty { store.reprocess(entry) } else { confirmRetry = true }
                    }
                    Spacer()
                    if entry.duration > 0 { Text(Duration.seconds(entry.duration).formatted(.time(pattern: .minuteSecond))).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }.disabled(store.busy)
            }
        }
        .sheet(isPresented: $editing) { TranscriptEditor(entry: entry).environmentObject(store) }
        .confirmationDialog("Delete this transcript and its retained recording?", isPresented: $confirmDelete) {
            Button("Delete transcript", role: .destructive) { store.deleteTranscript(entry) }
        } message: { Text("Imported original files are kept. This cannot be undone.") }
        .confirmationDialog("Replace this transcript?", isPresented: $confirmRetry) {
            Button("Transcribe again") { store.reprocess(entry) }
        } message: { Text("The saved audio will be processed using the current provider settings and the selected mode (\(store.selectedMode.name)).") }
    }
}
struct MeetingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel {
                Label("Meeting notes", systemImage: "person.2.wave.2").font(.title2.weight(.semibold))
                Text("Record meeting audio, then transcribe it. Configure a language model to also generate a summary, decisions and action items.").foregroundStyle(.secondary)
                Picker("Notes template", selection: $store.library.settings.meetingTemplate) { ForEach(MeetingTemplate.allCases) { Text($0.title).tag($0.rawValue) } }.onChange(of: store.library.settings.meetingTemplate) { _, _ in store.save() }
                Picker("Audio source", selection: $store.library.settings.meetingSource) {
                    ForEach(MeetingAudioSource.allCases) { Text($0.title).tag($0) }
                }.disabled(store.busy).onChange(of: store.library.settings.meetingSource) { _, _ in store.save() }
                MeetingPermissionsView(source: store.library.settings.meetingSource,
                    needsSpeechRecognition: (store.library.settings.meetingLiveTranslation &&
                        store.library.settings.meetingTranslationCaptionEngine == "apple") ||
                        (store.library.settings.liveCaptions && store.library.settings.liveCaptionEngine == "apple"),
                    busy: store.busy)
                Text("The full meeting is transcribed after Stop; optional provisional captions preview recent audio during recording. Speaker labels come from provider timestamps or the optional offline speaker model. Labels are anonymous and require review, especially overlapping speech.").font(.caption).foregroundStyle(.secondary)
                MeetingTranslationControls(service: store.meetingTranslation)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Meeting recordings folder", systemImage: "folder").font(.headline)
                    Text(store.meetingRecordingsPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Choose folder…") { store.chooseMeetingRecordingsFolder() }
                        Button("Show in Finder") { NSWorkspace.shared.open(store.recordingStorage.meetingDirectory) }
                        Button("Use default folder") { store.resetMeetingRecordingsFolder() }
                            .disabled(store.recordingStorage.usesDefaultMeetingDirectory)
                    }.disabled(store.busy)
                    Text("Applies to new meeting audio files. Existing recordings stay in their current folders. History remains in Cortala; configured audio retention still applies.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Keep audio after successful transcription (all recordings)", isOn: $store.library.settings.retainAudio)
                        .disabled(store.busy).onChange(of: store.library.settings.retainAudio) { _, _ in store.save() }
                    if !store.library.settings.retainAudio {
                        Text("Audio retention is off: successful recordings are removed after transcription. Failed recordings remain available for retry.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let warning = store.recordingStorage.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    Button("Import meeting recording…") { store.importAudio(asMeeting: true) }.disabled(store.busy)
                    Button(store.isStarting ? "Preparing audio…" : (store.isRecording ? "Finish recording" : "Record meeting")) { store.toggleRecording(asMeeting: true) }.buttonStyle(.borderedProminent).disabled(store.isStarting || store.isProcessing)
                    if store.busy { Button("Cancel") { store.cancel() } }
                }
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            if store.isRecording && (store.library.settings.liveCaptions || store.library.settings.meetingLiveTranslation) { ProvisionalCaptionsView() }
            if store.library.settings.meetingLiveTranslation {
                LiveMeetingTranslationPanel(service: store.meetingTranslation)
            }
            TextField("Search meeting transcripts", text: $search).textFieldStyle(.roundedBorder)
            MeetingSuggestionsView()
            let entries = store.library.history.filter { $0.isMeeting && (search.isEmpty || $0.raw.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search)) }
            if entries.isEmpty { EmptyCard(icon: "person.2", title: "Your meeting library", subtitle: "Completed transcripts and recordings awaiting a retry appear here.") }
            ForEach(entries) { TranscriptCard(entry: $0) }
        }
    }
}
struct ModesView: View {
    @EnvironmentObject var store: AppStore
    var body: some View { VStack(spacing: 16) {
        HStack { Text("A different workflow for every kind of thought.").foregroundStyle(.secondary); Spacer(); Button("New mode", systemImage: "plus") { store.library.modes.append(DictationMode(name: "Custom", icon: "sparkles")); store.save() } }
        ForEach($store.library.modes) { $mode in
            Panel {
                HStack { Image(systemName: mode.icon).foregroundStyle(.mint); TextField("Mode name", text: $mode.name).font(.title3).textFieldStyle(.plain); Spacer(); Button(store.selectedMode.id == mode.id ? "Selected" : "Use mode") { _ = store.chooseMode(mode.id) } }
                DisclosureGroup("Edit workflow") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Processing instructions · leave empty for raw transcription").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $mode.instruction).frame(height: 90).padding(6).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        Toggle("Adjust output tone", isOn: Binding(get: { mode.tone != nil }, set: { mode.tone = $0 ? 0.5 : nil }))
                        if mode.tone != nil {
                            HStack { Text("Casual"); Slider(value: Binding(get: { mode.tone ?? 0.5 }, set: { mode.tone = $0 }), in: 0...1, step: 0.25); Text("Formal") }
                            Text("User-selected tone: " + mode.toneDescription + ". Tone changes style only; instructions still preserve the meaning, facts and names.").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("Language code (auto, en, de, fr…)", text: $mode.language)
                        Text("auto uses the default language in Configuration. Set that default to auto for language detection. Translate mode needs a language model to translate to English.").font(.caption).foregroundStyle(.secondary)
                        Picker("Speech connection", selection: $mode.speechConnectionID) {
                            Text("Default speech provider").tag(nil as UUID?)
                            if let id = mode.speechConnectionID, !store.library.connections.contains(where: { $0.id == id && $0.kind == "speech" }) { Text("Missing speech connection · choose a replacement").tag(Optional(id)) }
                            ForEach(store.library.connections.filter { $0.kind == "speech" }) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Picker("Language connection", selection: $mode.rewriteConnectionID) {
                            Text("Default language provider").tag(nil as UUID?)
                            if let id = mode.rewriteConnectionID, !store.library.connections.contains(where: { $0.id == id && $0.kind == "rewrite" }) { Text("Missing language connection · choose a replacement").tag(Optional(id)) }
                            ForEach(store.library.connections.filter { $0.kind == "rewrite" }) { Text($0.name).tag(Optional($0.id)) }
                        }
                        DisclosureGroup("Model overrides (optional)") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Leave empty to inherit Models library. Overrides use the selected connection or default provider endpoints and credentials; choose a model supported by that provider.").font(.caption).foregroundStyle(.secondary)
                                TextField("Speech model ID", text: $mode.speechModelOverride)
                                PathField(title: "Local GGML model override", path: $mode.localModelOverride)
                                TextField("Language model ID", text: $mode.rewriteModelOverride)
                            }
                        }
                        TextField("Activate for app bundle IDs, separated by commas", text: $mode.appBundleIDs)
                        TextField("Activate for website domains, separated by commas", text: $mode.siteDomains)
                        Toggle("Assign a global shortcut", isOn: Binding(get: { mode.shortcut != nil }, set: { mode.shortcut = $0 ? HotKeySpec(keyCode: 0, modifiers: UInt32(controlKey | optionKey)) : nil }))
                        if mode.shortcut != nil { ShortcutEditor(title: "Mode shortcut", shortcut: Binding(get: { mode.shortcut ?? .toggle }, set: { mode.shortcut = $0 })) }
                        Toggle("Paste result into the originating app", isOn: $mode.autoPaste)
                        HStack { Button("Save mode") { store.applySettings() }; Spacer(); Button("Delete mode", role: .destructive) { store.library.modes.removeAll { $0.id == mode.id }; store.applySettings() }.disabled(store.library.modes.count < 2) }
                    }.padding(.top, 12)
                }
            }
        }
    } }
}
struct VocabularyView: View {
    @EnvironmentObject var store: AppStore
    @State private var phrase = ""
    @State private var replacement = ""
    var body: some View { VStack(spacing: 16) {
        Panel { Text("Make it sound like you.").font(.title2.weight(.semibold)); Text("Names and specialist terms are recognition hints. Optional replacements apply to whole words after transcription. CSV imports merge phrases ignoring case; imported replacements update matching phrases.").foregroundStyle(.secondary)
            HStack { TextField("Word or phrase", text: $phrase); TextField("Replace with (optional)", text: $replacement); Button("Add") { store.library.vocabulary.append(VocabularyEntry(phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines), replacement: replacement)); phrase = ""; replacement = ""; store.save() }.disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.textFieldStyle(.roundedBorder)
            HStack { Button("Import CSV…") { store.importVocabulary() }; Button("Export CSV…") { store.exportVocabulary() } }.disabled(store.busy)
        }
        ForEach($store.library.vocabulary) { $item in
            Panel { HStack { TextField("Phrase", text: $item.phrase); Image(systemName: "arrow.right").foregroundStyle(.secondary); TextField("Replacement (optional)", text: $item.replacement); Button("Save") { store.save() }.disabled(item.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); Button("Remove") { store.library.vocabulary.removeAll { $0.id == item.id }; store.save() } }.textFieldStyle(.roundedBorder) }
        }
    } }
}
struct SnippetsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View { VStack(spacing: 16) {
        Panel { Text("Say less. Write more.").font(.title2.weight(.semibold)); Text("A spoken trigger expands into saved text after recognition, before formatting. Use a distinctive phrase, such as insert my signature. Expansion matches whole words and ignores case.").foregroundStyle(.secondary)
            Button("New snippet", systemImage: "plus") { store.library.snippets.append(TextSnippet(trigger: "", text: "")); store.save() }
        }
        ForEach($store.library.snippets) { $snippet in
            Panel { TextField("Spoken trigger", text: $snippet.trigger).textFieldStyle(.roundedBorder); TextEditor(text: $snippet.text).frame(height: 100)
                HStack { Button("Save snippet") { store.save() }.disabled(snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || snippet.text.isEmpty); Spacer(); Button("Remove", role: .destructive) { store.library.snippets.removeAll { $0.id == snippet.id }; store.save() } }
            }
        }
    } }
}
struct StatisticsView: View {
    @EnvironmentObject var store: AppStore
    @State private var period = 30
    var body: some View {
        let stats = HistoryStatistics(entries: store.library.history, since: period == 0 ? nil : Calendar.current.date(byAdding: .day, value: -period, to: Date()))
        Panel {
            HStack { Text("Your activity").font(.headline); Spacer(); Picker("Period", selection: $period) { Text("7 days").tag(7); Text("30 days").tag(30); Text("All time").tag(0) }.frame(width: 150) }
            HStack(spacing: 28) { metric("Recordings", String(stats.recordings)); metric("Words", String(stats.words)); metric("Audio minutes", String(Int(stats.audioSeconds / 60))); metric("Active days", String(stats.activeDays)) }
            Text("Counts completed dictation and meeting transcripts. Imported files with unknown duration do not contribute audio minutes.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func metric(_ name: String, _ value: String) -> some View { VStack(alignment: .leading) { Text(value).font(.title2.monospacedDigit()); Text(name).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
}
struct ShortcutEditor: View {
    var title: String
    @Binding var shortcut: HotKeySpec
    var body: some View {
        HStack { Text(title).frame(width: 130, alignment: .leading); Picker("Key", selection: $shortcut.keyCode) { ForEach(HotKeySpec.keyChoices, id: \.code) { Text($0.name).tag($0.code) } }.frame(width: 150)
            modifier("Control", UInt32(controlKey)); modifier("Option", UInt32(optionKey)); modifier("Shift", UInt32(shiftKey)); modifier("Command", UInt32(cmdKey))
        }
    }
    private func modifier(_ title: String, _ flag: UInt32) -> some View { Toggle(title, isOn: Binding(get: { shortcut.modifiers & flag != 0 }, set: { if $0 { shortcut.modifiers |= flag } else { shortcut.modifiers &= ~flag } })).toggleStyle(.checkbox) }
}
struct TranscriptEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let entry: Transcript
    @State private var text: String
    @State private var learn = false
    @State private var reviewing = false
    @State private var suggestions: [CorrectionSuggestion] = []
    @State private var selected: Set<String> = []
    init(entry: Transcript) { self.entry = entry; _text = State(initialValue: entry.text) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reviewing ? "Review vocabulary corrections" : "Edit transcript").font(.title2.weight(.semibold))
            if reviewing {
                Text("Select the replacements you want to apply to future transcriptions. Matching phrases already in Vocabulary will be updated. Your transcript edits are saved regardless of which suggestions you select.").font(.callout).foregroundStyle(.secondary)
                ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(suggestions) { suggestion in Toggle(isOn: Binding(get: { selected.contains(suggestion.id) }, set: { if $0 { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) } })) { HStack { Text(suggestion.phrase); Image(systemName: "arrow.right"); Text(suggestion.replacement) } } } } }
            } else {
                TextEditor(text: $text).font(.body).frame(minHeight: 280)
                Toggle("Review vocabulary corrections from these edits", isOn: $learn)
                Text("The original recognized transcript is kept. Corrections are suggested only for bounded word changes present in the original recognition, and only added after you select them.").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); if reviewing { Button("Back") { reviewing = false } }; Button(reviewing ? "Save edits and selected corrections" : "Save edits") { save() }.buttonStyle(.borderedProminent).disabled(store.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 680, height: 470).onAppear { learn = store.library.settings.learnCorrections }
    }
    private func save() {
        if !reviewing && learn {
            suggestions = CorrectionLearning.suggestions(original: entry.text, edited: text, recognized: entry.raw)
            if !suggestions.isEmpty { reviewing = true; return }
        }
        if store.saveTranscriptEdits(entry, text: text, corrections: reviewing ? suggestions.filter { selected.contains($0.id) } : []) { dismiss() }
    }
}
struct ProviderConnectionsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Panel {
            HStack { Text("Provider connections").font(.headline); Spacer(); Menu("New connection") { Button("Speech API") { store.library.connections.append(ProviderConnection(name: "Speech connection", kind: "speech", endpoint: "https://api.openai.com/v1/audio/transcriptions", model: "whisper-1")); store.save() }; Button("Language model") { store.library.connections.append(ProviderConnection(name: "Language connection", endpoint: "http://localhost:11434/v1/chat/completions", model: "")); store.save() } } }
            Text("Assign an independent connection to each mode. Every connection stores its own key in Keychain, tied to its ID and endpoint origin (scheme, host and port). Changing hosts requires a new key; keys are excluded from exports and sync. A connection with no key never falls back to your default provider's key.").font(.caption).foregroundStyle(.secondary)
            ForEach($store.library.connections) { $connection in ProviderConnectionEditor(connection: $connection) }
        }.disabled(store.busy)
    }
}
struct ProviderConnectionEditor: View {
    @EnvironmentObject var store: AppStore
    @Binding var connection: ProviderConnection
    @State private var key = ""
    var body: some View {
        DisclosureGroup(connection.name + (connection.kind == "speech" ? " · Speech" : " · Language")) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Connection name", text: $connection.name)
                TextField("Exact API endpoint", text: $connection.endpoint).onChange(of: connection.endpoint) { _ in key = "" }
                TextField("Model ID", text: $connection.model)
                SecureField("New API key · leave empty to keep the stored key", text: $key)
                HStack { Button("Save connection") { store.saveConnection(connection, key: key); key = "" }; Button("Clear stored key") { store.clearConnectionKey(connection) }; Spacer(); Button("Remove connection", role: .destructive) { store.removeConnection(connection) } }
            }.textFieldStyle(.roundedBorder).padding(.top, 10)
        }
    }
}
struct ModelsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View { VStack(spacing: 20) {
        Panel {
            Label("Speech recognition", systemImage: "waveform").font(.title3.weight(.semibold))
            DictationSpeedPicker()
            Text("Selected speech model").font(.headline)
            Picker("Run transcription", selection: $store.library.settings.speechProvider) { Text("Local · whisper.cpp").tag("local"); Text("Cloud · compatible API").tag("cloud") }.pickerStyle(.segmented)
            if store.library.settings.speechProvider == "local" {
                Text("Choose an installed whisper-cli executable and a compatible GGML model. Audio stays on this Mac for transcription.").foregroundStyle(.secondary)
                PathField(title: "whisper-cli executable", path: $store.library.settings.localExecutable)
                PathField(title: "GGML model file", path: $store.library.settings.localModel)
                Label(FileManager.default.isExecutableFile(atPath: store.library.settings.localExecutable) ? "Executable found" : "Choose an executable to enable local recognition", systemImage: FileManager.default.isExecutableFile(atPath: store.library.settings.localExecutable) ? "checkmark.circle" : "exclamationmark.circle").font(.caption)
                Label(FileManager.default.isReadableFile(atPath: store.library.settings.localModel) ? "Model file found · validated when transcribing" : "Choose a downloaded GGML model", systemImage: FileManager.default.isReadableFile(atPath: store.library.settings.localModel) ? "checkmark.circle" : "exclamationmark.circle").font(.caption)
                ModelDownloadsView(downloads: store.modelDownloads)
                Link("whisper.cpp setup and models", destination: URL(string: "https://github.com/ggml-org/whisper.cpp")!)
            } else {
                Text("Audio is uploaded to the endpoint below. Provider usage charges apply to your account.").foregroundStyle(.secondary)
                HStack { Text("Preset"); ForEach(SpeechProviderPreset.all) { preset in Button(preset.name) { store.library.settings.speechEndpoint = preset.endpoint; store.library.settings.speechModel = preset.model; store.speechKey = "" } } }
                TextField("Transcription endpoint", text: $store.library.settings.speechEndpoint).onChange(of: store.library.settings.speechEndpoint) { _ in store.loadKeys() }
                TextField("Model ID", text: $store.library.settings.speechModel)
                SecureField("Speech API key", text: $store.speechKey)
            }
        }
        Panel {
            Label("Language model", systemImage: "sparkles").font(.title3.weight(.semibold))
            Text("Optional text formatting, meeting notes and questions. Ollama runs a language model to clean up or format recognized text; it does not recognize your speech here. Dictation with empty processing instructions skips this step. Formatting modes such as Email use a configured language model and can add delay after Stop.").foregroundStyle(.secondary)
            Text("Choose OpenAI-compatible chat completions, native Claude or Gemini, or a local Ollama / LM Studio server. Text is sent to this endpoint independently of speech recognition. Leave the model empty for raw transcription; modes can also select their own language connection.").font(.caption).foregroundStyle(.secondary)
            Menu("Choose language provider preset") { ForEach(ProviderPreset.allCases) { preset in Button(preset.title) { store.library.settings.rewriteEndpoint = preset.endpoint; store.library.settings.rewriteModel = ""; store.rewriteKey = "" } } }
            TextField("Language model endpoint", text: $store.library.settings.rewriteEndpoint).onChange(of: store.library.settings.rewriteEndpoint) { _ in store.loadKeys() }
            TextField("Model ID (required for formatting)", text: $store.library.settings.rewriteModel)
            Button("Use installed Ollama qwen3:8b") { store.library.settings.rewriteEndpoint = ProviderPreset.ollama.endpoint; store.library.settings.rewriteModel = "qwen3:8b"; store.rewriteKey = "" }
            SecureField("Language API key (empty for local servers)", text: $store.rewriteKey)
            Text("Choosing a provider preset clears the key and model. Enter a model available to your account and save providers.").font(.caption).foregroundStyle(.secondary)
        }
        DiarizationModelsView(models: store.diarizationModels)
        ProviderConnectionsView()
        HStack { Text("Keys are stored in macOS Keychain.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save providers") { store.save(); store.saveKeys() }.buttonStyle(.borderedProminent) }
    }.textFieldStyle(.roundedBorder) }
}
struct DiarizationModelsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var models: DiarizationModelService
    @State private var confirmRemove = false
    var body: some View {
        Panel {
            Label("Offline meeting speaker labels", systemImage: "person.2.wave.2").font(.headline)
            Text("FluidAudio separates speakers on this Mac using verified CoreML models (about 22 MB). Requires macOS 15 or later and timestamped speech recognition. Speaker numbers are anonymous; short turns and overlapping voices may be uncertain. Your audio is not sent to the model host.").font(.caption).foregroundStyle(.secondary)
            Toggle("Separate speakers in meeting transcripts", isOn: $store.library.settings.enableSpeakerSeparation).onChange(of: store.library.settings.enableSpeakerSeparation) { _ in store.save() }.disabled(store.busy)
            Text(models.status).font(.caption).foregroundStyle(.secondary)
            if models.isDownloading { ProgressView(value: models.progress); Button("Cancel speaker model download") { models.cancel() } }
            else { HStack { Button(models.isInstalled ? "Reinstall verified speaker models" : "Download speaker models") { models.install() }; if models.isInstalled { Button("Remove speaker models…", role: .destructive) { confirmRemove = true } } }.disabled(store.busy) }
            Link("FluidAudio source and license", destination: URL(string: "https://github.com/FluidInference/FluidAudio")!)
        }.confirmationDialog("Remove the downloaded speaker models?", isPresented: $confirmRemove) {
            Button("Remove speaker models", role: .destructive) { do { try models.remove(); store.library.settings.enableSpeakerSeparation = false; store.save() } catch { store.error = error.localizedDescription } }
        } message: { Text("Transcript text and existing speaker labels are kept. You can download the models again.") }
    }
}
struct ModelDownloadsView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var downloads: ModelDownloadService
    @State private var removing: LocalModelDescriptor?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download multilingual speech models").font(.headline)
            Text("Downloads use the official whisper.cpp model repository, check disk space, and verify size and SHA256 before installing. Canceled downloads restart from the beginning. A separate whisper-cli executable is required.").font(.caption).foregroundStyle(.secondary)
            ForEach(ModelDownloadService.catalog) { model in
                HStack {
                    VStack(alignment: .leading) { Text(model.name); Text(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let url = downloads.installedURL(for: model) {
                        Button(store.library.settings.localModel == url.path ? "Selected" : "Use model") { store.library.settings.localModel = url.path; store.save() }.disabled(store.busy)
                        Button("Remove…", role: .destructive) { removing = model }.disabled(store.busy || downloads.activeModelID != nil)
                    } else { Button("Download") { downloads.download(model) }.disabled(downloads.activeModelID != nil) }
                }
            }
            if downloads.activeModelID != nil { ProgressView(value: downloads.progress); Button("Cancel download") { downloads.cancel() } }
            Text(downloads.status).font(.caption).foregroundStyle(.secondary)
        }.confirmationDialog("Remove this downloaded model?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove model", role: .destructive) {
                guard let model = removing else { return }
                do { let selected = downloads.installedURL(for: model)?.path == store.library.settings.localModel; try downloads.remove(model); if selected { store.library.settings.localModel = ""; store.save() } }
                catch { store.error = error.localizedDescription }
                removing = nil
            }
        } message: { Text("Only the model in Cortala's managed model folder is removed. You can download it again later.") }
    }
}
struct MeetingSuggestionsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var calendar = CalendarMeetingService()
    @StateObject private var detector = MeetingAppDetector()
    @State private var showAppSuggestions = false
    var body: some View {
        Panel {
            Text("Meeting suggestions").font(.headline)
            Text("Calendar events and open meeting apps help you decide when to record. Recording always starts with your action. Calendar metadata stays on this Mac and is not included in model requests.").font(.caption).foregroundStyle(.secondary)
            Toggle("Suggest recording from meeting app activity", isOn: $showAppSuggestions).onChange(of: showAppSuggestions) { _, enabled in if enabled { detector.start() } else { detector.stop() } }
            if let status = detector.statusText { HStack { Label(status, systemImage: "video"); Spacer(); Button("Record meeting") { store.toggleRecording(asMeeting: true) }.disabled(store.busy) }; Text(detector.evidenceText).font(.caption).foregroundStyle(.secondary) }
            HStack { Text(calendar.authorizationText).font(.callout); Spacer(); if calendar.hasAccess { Button("Refresh") { calendar.refresh() } } else { Button(calendar.isRequesting ? "Connecting…" : "Connect Calendar…") { Task { await calendar.requestAccess() } }.disabled(calendar.isRequesting) } }
            if let error = calendar.error { Text(error).font(.caption).foregroundStyle(.orange) }
            ForEach(calendar.upcoming.prefix(8)) { event in
                HStack { VStack(alignment: .leading) { Text(event.title); Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarName)").font(.caption).foregroundStyle(.secondary) }; Spacer(); if event.suggestedNow() { Text("Starting soon").font(.caption).foregroundStyle(.mint) }; if let url = event.meetingURL { Link("Join", destination: url) }; Button("Record") { store.toggleRecording(asMeeting: true, title: event.title) }.disabled(store.busy) }
            }
        }.onAppear { calendar.startObserving(); if showAppSuggestions { detector.start() } }.onDisappear { calendar.stopObserving(); detector.stop() }
    }
}
struct PathField: View {
    var title: String; @Binding var path: String
    var body: some View { HStack { TextField(title, text: $path); Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK { path = panel.url?.path ?? path } } } }
}
struct SoundSettingsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Panel {
            Text("Recording sound").font(.title2.weight(.semibold))
            Toggle("Play recording start, stop and cancel sounds", isOn: $store.library.settings.soundFeedback)
            Toggle("Lower speaker output while recording", isOn: $store.library.settings.duckOutput)
            Text("Output ducking reduces supported output devices to 20% of their original volume. The original volume is restored after Stop or Cancel only if you have not changed it yourself. Some digital output devices do not expose volume controls. Headphones are recommended for meetings.").font(.caption).foregroundStyle(.secondary)
            if let warning = store.soundWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Button("Save sound settings") { store.save() }.buttonStyle(.borderedProminent)
        }.disabled(store.busy)
    }
}
struct ConfigurationView: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmClearHistory = false
    @State private var confirmPull = false
    var body: some View { VStack(spacing: 20) {
        Panel {
            Text("Recording & output").font(.headline)
            Picker("Appearance", selection: $store.library.settings.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented)
            TextField("Default language code (auto, en, de, fr, ml…)", text: $store.library.settings.language)
            Toggle("Paste completed dictation into the originating app", isOn: $store.library.settings.autoPaste)
            Picker("Recording indicator", selection: Binding(get: { store.library.settings.effectiveRecordingOverlayStyle }, set: { store.library.settings.recordingOverlayStyle = $0; store.library.settings.showOverlay = $0 != .none })) {
                Text("Classic").tag(RecordingOverlayStyle.classic); Text("Mini").tag(RecordingOverlayStyle.mini); Text("None").tag(RecordingOverlayStyle.none)
            }
            Picker("Microphone", selection: $store.library.settings.inputDeviceUID) {
                Text("System default").tag("")
                ForEach(AudioInputDevice.available()) { Text($0.name).tag($0.id) }
                if !store.library.settings.inputDeviceUID.isEmpty && !AudioInputDevice.available().contains(where: { $0.id == store.library.settings.inputDeviceUID }) { Text("Unavailable selected microphone").tag(store.library.settings.inputDeviceUID) }
            }.disabled(store.busy)
            Toggle("Show provisional dictation and meeting captions", isOn: $store.library.settings.liveCaptions)
            Picker("Caption engine", selection: $store.library.settings.liveCaptionEngine) { Text("Local Whisper · resident model").tag("local"); Text("Apple Speech · on-device streaming").tag("apple"); Text("Selected speech provider · rolling previews").tag("provider") }.disabled(store.busy)
            Text(store.library.settings.liveCaptionEngine == "local" ? "Local Whisper uses the selected local GGML model for bounded overlapping audio windows and keeps it resident across recordings. Captions stay on this Mac; final meeting audio still uses the selected full-recording provider. Source labels do not identify speakers." : store.library.settings.liveCaptionEngine == "apple" ? "Apple Speech incrementally recognizes actual capture buffers and requests Speech Recognition permission only when you start recording. On-device support for the selected language is required; an unavailable language or denied permission produces an explicit caption error without cloud fallback. With automatic language, captions use this Mac's language; your final speech model still uses its configured detection." : "Provider previews transcribe recent microphone or selected meeting-source audio about every six seconds. Cloud providers receive extra preview requests and may charge for them. This option is rolling recognition, not incremental streaming.").font(.caption).foregroundStyle(.secondary)
            Text("After Stop, the full recording is transcribed using the speech model selected by your mode. Live captions are provisional, never pasted, and do not replace that final transcript.").font(.caption).foregroundStyle(.secondary)
            ShortcutEditor(title: "Cancel recording", shortcut: $store.library.settings.cancelShortcut)
            ShortcutEditor(title: "Toggle recording", shortcut: $store.library.settings.toggleShortcut)
            ShortcutEditor(title: "Hold to record", shortcut: $store.library.settings.holdShortcut)
            ShortcutEditor(title: "Voice workflow", shortcut: $store.library.settings.workflowShortcut)
            Toggle("Enable mode switcher shortcut", isOn: Binding(get: { store.library.settings.modeSwitcherShortcut != nil }, set: { store.library.settings.modeSwitcherShortcut = $0 ? .modeSwitcher : nil }))
            if store.library.settings.modeSwitcherShortcut != nil { ShortcutEditor(title: "Mode switcher", shortcut: Binding(get: { store.library.settings.modeSwitcherShortcut ?? .modeSwitcher }, set: { store.library.settings.modeSwitcherShortcut = $0 })) }
            HStack {
                Picker("Mouse recording button", selection: $store.library.settings.mouseRecordingButton) { Text("Off").tag(nil as Int?); Text("Middle button").tag(Optional(2)); Text("Side button 1").tag(Optional(3)); Text("Side button 2").tag(Optional(4)) }
                Picker("Mouse gesture", selection: $store.library.settings.mouseRecordingBehavior) { Text("Toggle recording").tag(MouseRecordingBehavior.toggle); Text("Hold to record").tag(MouseRecordingBehavior.hold) }.disabled(store.library.settings.mouseRecordingButton == nil)
            }
            Text("Extra mouse buttons are off by default and may need macOS input-monitoring access. Keyboard and mouse holds each own only the recording they started; releasing one cannot stop another gesture's recording. Save settings to apply. The mode switcher offers Choose or explicit Record; mode-specific shortcuts remain in Modes.").font(.caption).foregroundStyle(.secondary)
            if let conflict = HotKeySpec.validationError(toggle: store.library.settings.toggleShortcut, hold: store.library.settings.holdShortcut, modes: store.library.modes, switcher: store.library.settings.modeSwitcherShortcut, workflow: store.library.settings.workflowShortcut, cancel: store.library.settings.cancelShortcut) { Text(conflict).foregroundStyle(.orange) }
            Toggle("Suggest vocabulary corrections when I explicitly edit a transcript", isOn: $store.library.settings.learnCorrections)
            Text("Learning compares only edits you save in History. Each proposed replacement requires your selection and confirmation; other apps are not monitored for corrections.").font(.caption).foregroundStyle(.secondary)
            Toggle("Use text copied within the last three seconds as context", isOn: $store.library.settings.captureRecentClipboard)
            Text("Clipboard context is off by default, limited to recently copied plain text, and excludes concealed/password-manager pasteboard types. It is captured only for an eligible destination and is sent only to your selected language model with context data; it is not saved in History.").font(.caption).foregroundStyle(.secondary)
            Toggle("Use nearby text as formatting context", isOn: $store.library.settings.captureFocusedText)
            Toggle("Use selected text as formatting context", isOn: $store.library.settings.captureSelectedText)
            Text("Context is optional, bounded, and excluded from secure fields. It is sent only to your selected language model, kept in memory for at most two minutes, and excluded from History unless you explicitly transform a selection. Website rules use the active browser address when available.").font(.caption).foregroundStyle(.secondary)
            Text("When selected-text context is enabled, a mode shortcut transforms selected text. With no selection it starts recording in that mode. You can also use Transform selection in the menu bar. A changed selection keeps the result here for review.").font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: Binding(get: { store.library.settings.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            Text(LoginItemService.statusText).font(.caption).foregroundStyle(.secondary)
            if let shortcutError = store.desktop.hotKeyError {
                Label(shortcutError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                Button("Retry registering shortcuts") { store.desktop.start(); store.objectWillChange.send() }
            }
            Text("Auto-paste needs Accessibility access for Cortala in System Settings. Microphone access is requested when you first record.").font(.caption).foregroundStyle(.secondary)
            Button("Open Accessibility settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
        }
        Panel {
            Text("Shared configuration folder").font(.headline)
            Text("Sync settings, modes, provider connections, vocabulary and snippets through a folder managed by iCloud Drive or another file sync app. Choose the initial source to enable automatic exchange every two seconds. Concurrent edits pause sync and preserve both configurations. Keys, history, recordings and this Mac's permissions/device paths stay local.").font(.caption).foregroundStyle(.secondary)
            Text(store.library.settings.configSyncFolder.isEmpty ? "No folder selected" : store.library.settings.configSyncFolder).font(.caption).textSelection(.enabled)
            HStack { Button("Choose folder…") { store.chooseSyncFolder() }; Button("Push this Mac's configuration") { store.pushConfiguration() }.disabled(store.library.settings.configSyncFolder.isEmpty || store.library.settings.autoSyncConfiguration); Button("Pull folder configuration…") { confirmPull = true }.disabled(store.library.settings.configSyncFolder.isEmpty || store.busy || store.library.settings.autoSyncConfiguration) }
            HStack {
                if store.library.settings.autoSyncConfiguration { Button("Stop automatic sync") { store.stopConfigurationSync() } }
                else { Menu("Enable automatic sync") { Button("Start with this Mac's configuration") { store.startConfigurationSync(.useLocal) }; Button("Start with the shared configuration") { store.startConfigurationSync(.useShared) }; Button("Resume previous sync baseline") { store.startConfigurationSync(.resume) } }.disabled(store.library.settings.configSyncFolder.isEmpty || store.busy) }
            }
            Text(store.syncStatus).font(.caption).foregroundStyle(.secondary)
        }
        Panel {
            Text("Local automation").font(.headline)
            Toggle("Allow same-user CLI and MCP commands", isOn: $store.library.settings.automationEnabled)
            Text("Save settings to apply. Local tools can read this user's transcript library and submit recording, mode, vocabulary and snippet commands while the app is running. Requests use private files on this Mac; no network server is opened.").font(.caption).foregroundStyle(.secondary)
        }
        Panel {
            Text("Privacy & storage").font(.headline)
            Toggle("Keep audio after successful transcription", isOn: $store.library.settings.retainAudio)
            Toggle("Keep retained recordings indefinitely", isOn: Binding(get: { store.library.settings.retentionDays == 0 }, set: { store.library.settings.retentionDays = $0 ? 0 : 30 }))
            if store.library.settings.retentionDays > 0 { Stepper("Keep successful recordings for \(store.library.settings.retentionDays) days", value: $store.library.settings.retentionDays, in: 1...365) }
            Text("Retention removes saved audio, while keeping transcript text. Recordings awaiting transcription remain until you delete their history entry. Turning audio retention off applies to future successful transcriptions.").font(.caption).foregroundStyle(.secondary)
            Text("History and settings are stored in ~/Library/Application Support/JustWisper. Cloud providers receive audio or text when you choose their endpoint.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Export configuration…") { store.exportConfiguration() }; Button("Import configuration…") { store.importConfiguration() }.disabled(store.busy) }
            HStack {
                Button("Show storage in Finder") { NSWorkspace.shared.open(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JustWisper")) }
                Spacer()
                Button("Delete all history…", role: .destructive) { confirmClearHistory = true }.disabled(store.busy || store.library.history.isEmpty)
            }
        }
        HStack { Spacer(); Button("Save settings") { store.applySettings() }.buttonStyle(.borderedProminent).disabled(store.busy) }
    }.textFieldStyle(.roundedBorder)
        .confirmationDialog("Apply the folder configuration?", isPresented: $confirmPull) {
            Button("Pull configuration") { store.pullConfiguration() }
        } message: { Text("Modes, vocabulary, snippets and portable settings will be replaced. A local backup is saved first. History, keys, device paths and privacy permissions stay on this Mac.") }
        .confirmationDialog("Delete all transcript history and retained recordings?", isPresented: $confirmClearHistory) {
            Button("Delete all history", role: .destructive) { store.clearHistory() }
        } message: { Text("This includes meetings and recordings awaiting transcription. Imported original files are kept. This cannot be undone.") }
    }
}
struct AccuracyView: View {
    @State private var reference = ""
    @State private var hypothesis = ""
    var body: some View { VStack(spacing: 20) {
        Panel { Text("Measure it on your own voice.").font(.title2.weight(.semibold)); Text("Compare transcripts of the same recording. Word error rate counts substitutions, insertions, and deletions against a verified reference. Lower is better. This comparison ignores punctuation and case.").foregroundStyle(.secondary)
            Text("Reference transcript").font(.headline); TextEditor(text: $reference).frame(height: 140)
            Text("Model transcript").font(.headline); TextEditor(text: $hypothesis).frame(height: 140)
            if !reference.isEmpty { HStack { Text(TextProcessing.wordErrorRate(reference: reference, hypothesis: hypothesis), format: .percent.precision(.fractionLength(1))).font(.system(size: 36, weight: .semibold, design: .rounded)).foregroundStyle(.mint); Text("word error rate").foregroundStyle(.secondary) } }
            Text("Evaluate Cortala on held-out recordings of English, your other languages, names, numbers, technical terms, corrections and noisy environments. Public fixtures do not measure accuracy on your own voice.").font(.caption).foregroundStyle(.secondary)
        }
    } }
}
