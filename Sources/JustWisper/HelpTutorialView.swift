import AppKit
import AVFoundation
import ApplicationServices
import Speech
import SwiftUI

enum SetupDestination {
    static func open(_ permission: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(permission)") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct WelcomeGuideView: View {
    @EnvironmentObject var store: AppStore
    @State private var step = 0
    private let titles = ["Turn speech into text", "Paste where you’re typing", "Capture meetings", "Stay in control of your data"]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("Welcome to Cortala", systemImage: "waveform").font(.title2.weight(.semibold))
                Spacer(); Text("\(step + 1) of \(titles.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text(titles[step]).font(.title.weight(.semibold))
            Group {
                switch step {
                case 0:
                    Text("Choose Fast for words as you speak, or Accurate to use your selected speech model after Stop. Start and stop with the recording button or your global shortcut.")
                    Label(store.library.settings.toggleShortcut.displayName + " to toggle recording", systemImage: "keyboard")
                    Text("Microphone access is requested only when you start recording. You can review and copy the result in Home.")
                case 1:
                    Text("Click a text field in another app first, then use your global shortcut to start and stop. Keep focus in that field until the final text is inserted.")
                    Text("Auto-paste needs Accessibility permission. Recording inside Cortala is useful for reviewing and copying text here.")
                    Button("Open Accessibility settings") { SetupDestination.open("Accessibility") }
                case 2:
                    Text("In Meetings, choose microphone, system audio, or both. Audio only is currently supported. Obtain the participants’ permission before recording.")
                    Text("For live translation, choose From and To and prepare the languages before recording. Speaker labels and the final original transcript are produced after Stop.")
                    Text("Choose a folder for new meeting recordings. Enable audio retention if you want successful audio files kept afterward.")
                default:
                    Text("Local speech recognition stays on this Mac. Cloud speech sends audio; cloud formatting sends text. Review your selected provider before recording.")
                    Text("API keys use Keychain. You can enable encrypted transcript storage in Help & Tutorial. Audio, exports and old backups are separate; retention and failed-recording recovery are explained there.")
                    Text("External links now ask before controlling recording or importing a file. Optional context, Calendar and local automation stay under your control.")
                }
            }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Skip for now") { store.completeWelcome() }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == titles.count - 1 ? "Get started" : "Next") {
                    if step == titles.count - 1 { store.completeWelcome() } else { step += 1 }
                }.buttonStyle(.borderedProminent)
            }
            Text("You can reopen this guide anytime in Help & Tutorial.").font(.caption).foregroundStyle(.secondary)
        }.padding(30).frame(width: 620, height: 480)
    }
}

struct HelpTutorialView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel {
                HStack { Label("A quick start", systemImage: "book.closed").font(.title2.weight(.semibold)); Spacer(); Button("Show welcome guide") { store.showingWelcome = true } }
                Text("1. Choose a mode in Home. For plain text with the shortest delay, use Dictation.")
                Text("2. Use \(store.library.settings.toggleShortcut.displayName) to start and stop. Hold mode uses \(store.library.settings.holdShortcut.displayName).")
                Text("3. Focus the destination field before Stop and keep it unchanged until insertion. The result preview stays on screen for five seconds. Hover to keep it open, or use the Copy button. History keeps the transcript too.")
            }
            SetupPermissionsView()
            PrivacySetupView()
            Panel {
                Label("Meetings and translation", systemImage: "person.2").font(.headline)
                Text("Choose Audio source before recording: Microphone for your voice, System audio for sound from other apps, or both with headphones. The app currently saves audio, not video. Get participants’ permission before recording.")
                Text("Live translation: enable it, choose From and To, then Prepare languages. When languages are ready, record the meeting. Captions and translated previews can change or pause; the full original recording is transcribed after Stop.")
                Text("Speaker separation in Models library creates anonymous speaker labels after Stop. It does not recognize people by name. Overlaps and short turns need review.")
                Text("Use Meetings → Choose folder to change where new audio is stored. Existing files stay put. Successful audio is deleted unless retention is on; failed recordings remain available for retry.")
            }
            Panel {
                Label("Names, specialist terms and corrections", systemImage: "book").font(.headline)
                Text("Add the correct word in Vocabulary with a blank Replacement to give the recognizer a hint. Use a specific mistaken phrase and its replacement for repeatable errors. Avoid broad corrections that change valid words.")
                Text("Edit a saved transcript to fix mistakes. If correction learning is enabled, review and approve suggestions before they enter your vocabulary. Snippets expand short triggers into longer text.")
            }
            Panel {
                Label("Voice workflows", systemImage: "list.bullet.rectangle").font(.headline)
                Text("In Workflows, choose a phrase and add actions to open apps, open websites, search the web or wait. Reorder the steps and save. Use Record command to speak the exact phrase; regular dictation never executes actions. Use Control–Shift–Space anywhere to start and stop command recording. Enabled matches run immediately.")
                Text("Copy JSON shares one workflow. Paste shared JSON into the import area, import it disabled, review its actions, then enable it. Importing never runs a workflow. Action values are included in exports, so review them before sharing.")
                Text("Enabled spoken matches run immediately; Preview / Run offers a manual review. Stop workflow skips remaining steps; apps and pages already opened stay open. Closing windows and automatically starting another app’s voice mode are not supported.")
            }
            Panel {
                Label("If something goes wrong", systemImage: "wrench.and.screwdriver").font(.headline)
                Text("No paste: check Accessibility access and place your cursor in the target field before Stop. The transcript remains in History if focus changes.")
                Text("Long dictation: Fast may need local Whisper recovery when Apple cannot finalize all words. The saved original audio is used; no automatic cloud audio upload is added.")
                Text("Silent dictation: stopping without recognized speech returns to Ready, with no paste or empty transcript. Actual permission or service failures still show an explanation.")
                Text("Meeting capture denied: microphone-only recording needs Microphone access. Capturing other apps needs Screen & System Audio Recording access. Change the audio source if system audio is unnecessary.")
            }
        }
    }
}

struct SetupPermissionsView: View {
    @State private var microphone = false
    @State private var accessibility = false
    @State private var speech = false
    @State private var screen = false
    var body: some View {
        Panel {
            Label("Permissions · grant only what you use", systemImage: "checklist").font(.headline)
            permission("Microphone", detail: "Needed to record your voice.", allowed: microphone, destination: "Microphone")
            permission("Accessibility", detail: "Optional: insert text into other apps.", allowed: accessibility, destination: "Accessibility")
            permission("Speech Recognition", detail: "Needed for the Apple Speech engine.", allowed: speech, destination: "SpeechRecognition")
            permission("Screen & System Audio Recording", detail: "Needed only to capture sound from other apps.", allowed: screen, destination: "ScreenCapture")
            Text("These buttons open macOS settings. You approve each permission yourself; no permission is enabled automatically.").font(.caption).foregroundStyle(.secondary)
        }.task { refresh() }.onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }
    private func permission(_ title: String, detail: String, allowed: Bool, destination: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle").foregroundStyle(allowed ? .mint : .secondary)
            VStack(alignment: .leading, spacing: 3) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Text(allowed ? "Allowed" : "Not enabled").font(.caption).foregroundStyle(.secondary)
            Button("Open settings") { SetupDestination.open(destination) }
        }
    }
    private func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        screen = CGPreflightScreenCaptureAccess()
    }
}

struct MeetingPermissionsView: View {
    let source: MeetingAudioSource
    let needsSpeechRecognition: Bool
    let busy: Bool

    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var requesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions for this meeting").font(.headline)
            if source != .system {
                permission("Microphone", status: microphoneStatus, allowed: microphone == .authorized,
                           destination: "Microphone", request: microphone == .notDetermined ? requestMicrophone : nil)
            }
            if source != .microphone {
                permission("Screen & System Audio Recording", status: screen ? "Allowed" : "Screen access not enabled",
                           allowed: screen, destination: "ScreenCapture", request: screen ? nil : requestScreen)
            }
            if needsSpeechRecognition {
                permission("Speech Recognition", status: speechStatus, allowed: speech == .authorized,
                           destination: "SpeechRecognition", request: speech == .notDetermined ? requestSpeech : nil)
                Text("Apple live captions need Speech Recognition. Meeting audio can still be recorded without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var microphoneStatus: String {
        switch microphone {
        case .authorized: return "Allowed"
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        default: return "Not allowed"
        }
    }

    private var speechStatus: String {
        switch speech {
        case .authorized: return "Allowed"
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        default: return "Not allowed"
        }
    }

    private func permission(_ title: String, status: String, allowed: Bool, destination: String,
                            request: (() -> Void)?) -> some View {
        HStack {
            Label(title, systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
            Text(status).font(.caption).foregroundStyle(allowed ? Color.secondary : Color.orange)
            Spacer()
            if let request {
                Button("Request access", action: request)
                    .accessibilityLabel("Request \(title) access")
                    .disabled(busy || requesting)
            }
            if !allowed {
                Button("Open Settings") { SetupDestination.open(destination) }
                    .accessibilityLabel("Open \(title) settings")
            }
        }
    }

    private func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        speech = SFSpeechRecognizer.authorizationStatus()
        screen = CGPreflightScreenCaptureAccess()
    }

    private func requestMicrophone() {
        requesting = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
            requesting = false
        }
    }

    private func requestSpeech() {
        requesting = true
        SFSpeechRecognizer.requestAuthorization { _ in
            Task { @MainActor in
                refresh()
                requesting = false
            }
        }
    }

    private func requestScreen() {
        if !CGRequestScreenCaptureAccess() { SetupDestination.open("ScreenCapture") }
        refresh()
    }
}

struct PrivacySetupView: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmEncryption = false
    var body: some View {
        Panel {
            Label("Privacy and storage", systemImage: "lock.shield").font(.headline)
            Text(store.dataFlowDescription).font(.callout)
            Text("API keys are stored in macOS Keychain. Optional context can add nearby, selected or recently copied text to formatting requests. Review those opt-ins in Configuration.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Label(store.transcriptEncryptionEnabled ? "Saved transcript library encrypted" : "Saved transcript library not encrypted by the app", systemImage: store.transcriptEncryptionEnabled ? "lock.fill" : "lock.open")
                Spacer()
                if !store.transcriptEncryptionEnabled { Button("Enable transcript encryption…") { confirmEncryption = true }.disabled(store.busy) }
                else if store.hasPlaintextLibraryCopy { Button("Finish encryption cleanup…") { confirmEncryption = true }.disabled(store.busy) }
            }
            Text("Encryption protects the current saved library with a key held in this Mac’s Keychain. Audio recordings, exports, synchronized settings and older backups are not encrypted by this control. It does not protect against malware running as you or an unlocked compromised Mac.").font(.caption).foregroundStyle(.secondary)
            if let warning = store.vaultWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            Toggle("Keep audio after successful transcription", isOn: $store.library.settings.retainAudio).disabled(store.busy).onChange(of: store.library.settings.retainAudio) { _, _ in store.save() }
            Text("Failed recordings are retained for retry even when successful audio retention is off. Deleting a transcript through History also removes its managed audio; imported originals are kept.").font(.caption).foregroundStyle(.secondary)
            Text("This is a development build: ad-hoc signed, not notarized, and not independently security-audited. The code review found and fixed specific issues; it is not a guarantee that every dependency is vulnerability-free.").font(.caption).foregroundStyle(.secondary)
        }.confirmationDialog("Encrypt the saved transcript library?", isPresented: $confirmEncryption, titleVisibility: .visible) {
            Button("Encrypt library") { store.enableTranscriptEncryption() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The library will need its device Keychain key to reopen. Keep a secure export of important transcripts before moving to another Mac. The existing library is removed only after a verified encrypted copy is saved. Audio and older backups remain separate.")
        }
    }
}
