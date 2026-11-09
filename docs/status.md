# JustWisper implementation evidence

Updated 2026-10-22. This is an evidence record for an initial personal build. Implemented source, passing automated checks and observed runtime behavior are separate. Superwhisper feature parity and Wispr Flow accuracy parity remain unestablished.

## Observed runtime evidence

- Approved multilingual medium GGML model downloaded to `Models/ggml-medium.bin`: 1,533,763,059 bytes; SHA-256 `6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208` verified. Source: [ggerganov/whisper.cpp GGML medium](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-medium.bin); runtime: [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Runtime/model license and redistribution notices still need a release audit before bundling either dependency for distribution.
- Local runtime smoke test passed on this Mac with normal GPU access: `/opt/homebrew/bin/whisper-cli -m Models/ggml-medium.bin -f /opt/homebrew/share/whisper.cpp/jfk.wav -l en -nt`. Output: “And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.” Runtime logged 2,168 ms total. A sandboxed attempt could not allocate GPU resources; execution outside that restriction succeeded.
- That engine test validates the installed runtime/model on a public fixture. Microphone recording, auto-paste, multilingual output and user-voice accuracy require separate checks. The app import and persistence results are recorded below.

## Source implementation in this build

- Native SwiftUI window/menu bar, toggle/hold shortcuts, microphone capture/level overlay, local whisper.cpp and cloud multipart transcription, optional independent chat-completions formatting, Keychain keys.
- Default local runtime/model detection; English, automatic detection and explicit language codes; Translate mode through the language model.
- Original destination capture/validation, paste refusal for unsupported or changed destinations, clipboard restoration safeguards, recording gesture ownership/startup guards.
- Durable history before formatting, recovery audio, playback, retry, confirmed deletion, audio retention, imported-original preservation and unreadable-library backup protection.
- Meeting microphone/system/mixed capture wired to UI with explicit permissions and current feature limitations.
- Audio/video import and Finder URL handling; validated URL command dispatch; visible shortcut-registration errors; separate speech/formatting route descriptions.

## Extended feature implementation (acceptance in progress)

Source now includes:

- Independent per-mode speech/language provider connections (UUID, purpose, endpoint, model), origin-scoped Keychain credentials and explicit missing-connection failures, plus per-mode model ID/local-path overrides and editable toggle/hold/per-mode shortcuts with validation and visible registration failures; app/site matching; user-triggered macOS login registration.
- Opt-in nearby/selected text context with sensitive-field exclusions, bounded in-memory lifetime and separate model data messages. Mode shortcuts transform selected text when enabled, with original selection/field validation before insertion. Explicit transformations are retained in History; incidental context is not.
- Vocabulary editing and RFC 4180-style CSV import/export; snippets before formatting; saved-raw-text reformatting; Home activity statistics.
- Meeting templates and original-transcript-grounded questions through the selected language model; available timestamps/speaker metadata; long-audio chunk processing. Provider metadata is not an evaluated speaker separation system.
- User-selected input devices and opt-in rolling dictation/meeting captions (recent 24-second snapshots, about six-second refresh). The selected-provider engine makes periodic recognition requests; cloud previews incur additional usage. A separate Apple Speech engine now consumes actual capture buffers for incremental hypotheses, guarded by supportsOnDeviceRecognition plus requiresOnDeviceRecognition. Speech permission is requested only at an explicitly started recording with that option enabled. Unsupported languages/denied permission show a caption error without remote fallback. Separate mic/system recognition sessions serve mixed meetings and label inputs rather than identities. Pure fixtures test partial replacement/final deduplication, bounded utterance accumulation and copying callback audio before queue crossing. Live permissioned engine acceptance remains open.
- Optional real offline speaker separation through pinned FluidAudio CoreML segmentation/embedding/VBx models (macOS 15+), with an explicit verified download/cancel/remove UI and anonymous-label alignment to speech timestamps. Raw recognized text is saved before speaker analysis; failures are explicit and retain recovery audio. Speaker accuracy has not been measured on the user's meetings.
- Explicit History transcript editing, optional suggestions from actual edit diffs, and user-selected confirmation before vocabulary updates. Arbitrary/unreviewed correction payloads are rejected. Original raw recognition is preserved. No cross-app correction monitoring.
- Private library directory (0700), library/backup files (0600), origin-scoped default keys, and UUID-plus-origin-scoped connection keys. Key material is excluded from encoded configuration.
- Default-off recording sound cues and output ducking with restoration safeguards, plus system/light/dark appearance.
- A managed multilingual-model catalog with progress/cancel/removal, disk-space checks and SHA256/size verification. Downloads have not been exercised through UI in this phase.
- Explicit Calendar connection and manual event recording with event titles; opt-in meeting-app suggestions distinguish CoreAudio active microphone evidence on macOS 14.2+ from an open-app fallback. This metadata cannot distinguish an actual call from a microphone test. Recording always requires a user action.
- Automatic configuration exchange through a chosen file-sync folder with explicit initial source, persisted baseline/resume, two-second polling, revision ancestry and immutable revision snapshots. Concurrent changes pause with preserved conflict copies and require explicit resolution. Manual Push/Pull remain. Keys/history/audio and machine permissions/paths are omitted; remote application waits until idle and first saves a private local backup. See [configuration sync](configuration-sync.md).
- Default-off local CLI/MCP queue handling keeps the live app as the sole library writer. See integration validation below as it is completed.

Feature source is not proof of end-to-end acceptance. Permission-dependent features remain unverified until individually exercised with user-granted access.

## Integration evidence from the current extension

- Root exercised the MCP `initialize` and `tools/list` stdio exchange: protocol `2025-06-18`, 14 tools returned. This is a protocol smoke check, not recording or permission validation.
- The standalone Python CLI/MCP test suite passed its three initial tests (desktop integration owner). The app's live mutation queue still needs an explicit enabled-setting acceptance run.
- Additional Swift regression fixtures cover quoted CSV Unicode/multiline round trips, malformed CSV rejection, noncascading snippets, completed-history date filtering, per-mode model resolution without endpoint changes, and shared-file conflict preservation. The extension checkpoint passed all 42 tests across 10 suites; the compiler build took 7.4 seconds and test execution 0.341 seconds using `scripts/test.sh --scratch-path /tmp/justwisper-audio-build`.

- Separate enabled local executions passed via `JUSTWISPER_LOCAL_SMOKE=1 JUSTWISPER_OLLAMA_SMOKE=1 scripts/test.sh --scratch-path /tmp/justwisper-audio-build --filter 'RewriteProtocolTests|AudioProviderExecutionTests'`: seven tests, including real medium-model JFK inference with genuine timestamps (5.356 seconds) and local Ollama `qwen3:8b` formatting on public hello-world data (19.925 seconds). Metal GPU and localhost access required execution outside the sandbox restriction. These are pipeline checks, not user-accent accuracy evidence. Native paid-provider adapters were exercised with request/response fixtures; no paid provider calls were made.

## Earlier automated checks and app smoke results

- Normal test suite: 13 tests discovered, 12 executed and passed; 1 gated local inference test skipped in that run.
- The separately enabled local inference test passed through the actual `TranscriptionService` using the approved GGML medium model and JFK fixture, taking 2.218 seconds and meeting its WER assertion of less than 25%. This validates that fixture through the service; it is not an accuracy-parity result.
- Release packaging succeeded: `dist/JustWisper.app` created. The build owner verified its ad-hoc signature and bundle plist. App launch/import/persistence QA passed as recorded below.
- Audio conversion was corrected to stop at end of input before the successful normal suite. Broader media-container and cancellation fixtures remain separate acceptance work.
- The release app launched successfully. Visual inspection found a clean native dark/mint window at 1120 × 760 logical pixels. Models library detected `/opt/homebrew/bin/whisper-cli` and the workspace GGML medium model path; the sidebar correctly showed raw-text formatting status.
- Native file-picker import of `/opt/homebrew/share/whisper.cpp/jfk.wav` completed with “Transcript ready”. Latest transcript and History both contained the expected sentence from the CLI fixture above. No provider or permission error appeared. Imported output stayed in review and no automatic paste was triggered.
- Quit with Command–Q and relaunch restored the exact fixture transcript in History. Latest transcript was empty after relaunch, consistent with its in-memory lifetime. The app was left open on Home.
- Microphone recording, Accessibility insertion and meeting/system-audio permissions were not exercised in this UI smoke test.

Manual acceptance remains for microphone permission denial/grant, first/last-word capture, hold release during startup, microphone/system/mixed meetings, target-field insertion/refusal, clipboard changes, cancellation/quit during active work, corrupt/disk-full storage, retained-audio retry/deletion, supported media containers and language/translation fixtures. Cloud success and failure behavior require protocol tests plus a live user-configured account. No live credentialed cloud test has been run.

Permissioned live Apple Speech acceptance, evaluated speaker-separation accuracy, confirmed active-call detection and distribution signing/notarization remain parity gaps. Folder sync deliberately preserves concurrent conflicts for explicit resolution rather than merging semantic settings edits. The extended feature source above requires its own acceptance evidence. A held-out user-voice corpus is required before accuracy claims about the user's speech. The user chose independent JustWisper evaluation; a Flow baseline is outside the current acceptance scope.

## Current completion pass

Version 0.2.0 wires the provider routes, correction-review editor, automatic folder sync, Apple Speech incremental/selected-provider rolling meeting captions and offline speaker-model lifecycle into the native app. Meeting summary/question data now includes only real stored ASR timestamps and available anonymous speaker labels, with explicit overlap/identity uncertainty instructions. The final source snapshot passed 89 Swift tests across 21 suites; the corrected release package was installed and launched, with the newest native UI checks recorded below. No microphone, Accessibility, Calendar or system-audio permission was granted by an agent, and no live private recording or paid cloud call was made in this pass. Live user acceptance and a held-out accuracy corpus remain required.

Apple Speech implementation references: [live buffer requests](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest) and [requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition). The implementation checks on-device support before requiring device-only recognition, appends copied capture buffers, reports partial hypotheses and starts a new request after utterance completion. This source workflow is not proof that every Mac/language has an installed on-device speech model.

The final reference-scope additions include per-mode Casual–Formal tone as a separate grounded instruction suffix, strict URL mode selection by UUID or exact unambiguous name, indefinite audio retention (persisted zero-day sentinel, no expiration), and Meetings import of an existing recording through the real meeting/template/diarization pipeline. Focused fixtures cover tone/raw-mode behavior, URL validation/persistence and indefinite-retention preservation. These additions are included in the final passing 89-test snapshot. Earlier checkpoint results above remain historical evidence for those earlier snapshots.

Automatic synchronization publishes only successfully saved configuration snapshots. Unsaved editor drafts remain local and defer incoming application until saved; manual Push/Pull controls are disabled while automatic exchange is active. A deterministic AppStore integration fixture checks that an unsaved vocabulary draft is not published, then propagates after Save.

## Current evaluation scope

The user chose to evaluate JustWisper independently for now and declined a Flow baseline. Vendor comparison is therefore not a remaining acceptance goal. Public fixtures and the reproducible local benchmark document operation on known audio; accuracy on the user's private speech and real microphone-to-insertion behavior remain unmeasured. The [complete feature status](feature-status.md) distinguishes native implementation, automated evidence and permission-dependent acceptance.

The final source snapshot passed all 89 Swift tests across 21 suites, taking 32.981 seconds after a 9.44-second incremental build. This includes mouse/hold ownership, paired mouse gestures, recent-clipboard privacy/expiry, mode-switcher navigation, overlay migration, saved-only configuration publication through unrelated History/mode changes, shutdown recovery and fast-dictation routing. The enabled genuine Whisper/WER, local Ollama and CoreML plus two-speaker ASR checks also passed. Seven Python integration tests passed. The corrected release package was installed in `~/Applications/JustWisper.app` and launched successfully. This does not claim live microphone/Speech permission or insertion validation.

Fast on-device dictation is now an explicit option for new microphone dictation. It uses Apple's real incremental audio recognition, shows provisional words in the app and a bounded recent-word preview in the floating overlay, and awaits genuine final recognition for up to five seconds after capture stops. Successful final recognition goes directly to saved raw text and optional formatting, without another full Whisper pass. Provisional words are never inserted into another application; stable text is pasted after Stop using the existing destination checks. Meetings and imported audio continue through the selected full-recording engine. Unsupported/denied Speech recognition, incomplete final results and timeout are explicit failures; finalized audio is staged in History before finalization for an explicit selected-model Retry. No live permissioned Apple streaming or latency measurement has been performed yet.

Ollama serves optional text formatting, independently of the speech engine. Raw Dictation has no formatting instruction and skips language processing. The user's saved configuration currently has an empty formatting-model field, so it does not request Ollama cleanup unless a formatting model and an instructed mode are selected. A failed optional formatting route preserves the already-saved stable raw transcript and recovery audio.

History persistence now writes committed configuration plus current History, and mode selection commits only the selected identity; neither silently publishes unrelated editor drafts. Explicit configuration Save still commits those edits. Normal application termination now restores sound state before its first suspension, stops new work, finalizes active capture into pending History and cancels processing while preserving recovery audio. Regression fixtures cover queued capture bytes and private drafts; physical device restoration and active-capture shutdown remain live acceptance work.


The installed final app was visually checked on Home: both Accurate and Fast selectors were present, Fast was enabled at the user's explicit speed request, and the on-device availability/Speech permission guidance was visible. The existing 14 recordings remained present. No recording was started during this check; actual Apple Speech availability, permission grant, live word timing, final capture quality and destination insertion still require the user-driven recording check.


The final ZIP was independently extracted and passed ad-hoc signature verification plus an audit of all 11 bundled Mach-O files and their runtime paths. The package script removes the compiler's temporary absolute build path. An isolated standalone bundled-engine run from `/tmp`, with a minimal environment and no Homebrew path, loaded its own Metal library on Apple M4 Pro and produced the correct JFK transcript with 22 genuine word segments. Reported inference was 1.635 seconds; first shader compilation added 21.783 seconds in that run. This is packaging/runtime evidence on public audio, not a live microphone latency result.

## Long streaming recovery

User acceptance confirmed Codex insertion after conservative Accessibility identity recovery. A subsequent live long-dictation failure reported incomplete Apple utterance finalization. Fast dictation now retains the staged full recording and automatically invokes the configured local speech model when Apple finalization fails. A global cloud provider or per-mode speech connection prevents automatic recovery, avoiding an unexpected audio upload. Incomplete previews are never inserted as final text. Fifteen focused streaming, fast-dictation and destination tests pass; real long-recording recovery remains to be accepted in the updated installed build.

## Quiet no-speech outcome

Fresh dictation recordings now treat an empty recognizer result, explicit blank-audio markers, and Apple's documented no-speech error as no action: no paste, no empty History entry and no alert. An effectively zero PCM capture is skipped before provider processing. The threshold is deliberately conservative to avoid rejecting quiet real speech. Permission and recognizer-service errors remain actionable; imported files and meeting recovery audio retain their existing explicit review paths. Apple error mapping reference: https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error. Automated regression and installed-build checks are tracked in the current acceptance pass.

Silent-stop acceptance pass: 107 Swift tests across 25 suites passed, including four new no-speech regressions. The package passed its strict signature check and replaced the existing user Applications app; generated duplicate app bundles were moved to Trash. A real microphone silence test remains user acceptance.


## Security, storage and onboarding acceptance

The integrated security build passed 123 Swift tests across 29 suites and eight Python checks. Public JFK audio passed the local engine smoke check in 2.208 seconds; this does not measure live dictation latency. The packaged and cleanly installed bundles passed the static inventory gate: main application plus ten runtime native payloads, manifest hashes, publisher notices, internal symlinks, portable loader paths and strict ad-hoc signature verification. An initial copy over the previous installed bundle retained obsolete notice files and failed its resource seal; replacing the whole bundle rather than merging corrected this, and the installed audit passed again. No unrelated software was installed.

The four-step welcome guide and permanent Help & Tutorial page were checked in the installed native interface, including data flow, permission links and optional encryption controls. The personal library has **not** been migrated automatically: enable transcript encryption explicitly in Help & Tutorial. Audio, exports, synchronized settings and older backups are outside that vault. The build is ad-hoc signed, not notarized, sandboxed or independently security-audited. Current permission indicators reported not enabled after the rebuild; live permissions and capture require user acceptance for this installed identity.

External command links and incoming file URLs now queue an explicit approval; stale recording approvals expire. Local subprocess environment overrides and oversized model downloads are restricted. Encrypted libraries fail closed on missing keys or failed authentication; the Python integration refuses plaintext fallback while a vault exists. See security-review.md for scope and limitations.


## Shareable voice workflow acceptance

The integrated workflow build passed 132 Swift tests across 30 suites with normal filesystem access, including nine new workflow tests. A final route fix makes explicit commands use the selected mode rather than a stale destination-matched mode. The release package and clean installed bundle passed the native inventory/notices/hash/signature audit; the ZIP passed CRC and metadata checks. Installation replaced the old bundle cleanly, preserving it in Trash rather than merging resources. Generated duplicate build apps were moved to Trash; the installed app and distributable ZIP remain.

Native UI verification imported a harmless single-wait JSON fixture whose exported enabled flag was true. The imported workflow appeared disabled, showed an explicit ordered preview, and executed only the zero-second wait after Run these actions. A disabled Example: Wait starter was saved in the library. No external app or website was launched by this verification, and no microphone capture or private audio upload was performed. Live spoken phrase recognition remains user acceptance.

Supported blocks are opening installed apps, HTTPS websites, fixed Google searches and bounded waits, with editable/reordered sequences and copy/paste versioned JSON. Workflows are part of the optionally encrypted library and excluded from automatic configuration sync. Unsupported actions include window closing, window arrangement, arbitrary scripts and automatically starting ChatGPT Voice. See voice-workflows.md for sharing boundaries and limits.


## Final Mac resident-recognition update

The combined Mac update passed 150 Swift tests in 34 suites, including local model reuse/window replay, translation lifecycle and provider requests, workflow shortcut ownership/immediate execution, physical-display fallback policy and bounded session error logging. The release ZIP passed CRC and the package plus cleanly replaced installed app passed the exact native inventory, publisher notices/hashes, portable loader-path and strict ad-hoc signature audit (main app plus eleven runtime natives). Generated build/temporary app duplicates were moved to Trash. The user Applications copy and ZIP remain.

Installed UI checks verified Home's resident local-model state, selected Live → Local Whisper, and showed model ready. First installed cold startup reported 22.53 seconds; a later cached launch reported 0.16 seconds. These are observed starts, not a guarantee. Errors displayed its nonmodal empty-session page. Workflows showed the dedicated Control–Shift–Space command shortcut and immediate-match behavior; an unsaved inspection draft exposed the physical-display picker/fullscreen controls and was reset without altering saved user workflows. No real workflow/window placement or microphone recording was executed by this acceptance pass. Further UI automation stopped when the client reported concurrent user app changes.

The stop-time paste destination is captured before final processing while optional recognition context is preserved separately. Clicking Stop in JustWisper retains the external destination rather than targeting JustWisper itself. A missing/changed/unsupported destination retains the transcript and offers a three-second copy-icon overlay; hover cancels dismissal and leaving starts a fresh three-second interval. Paste integration failures no longer raise modal alerts. Genuine errors appear in a bounded, session-only Errors page; external-command/import approval remains separate. Live destination switching and copy-overlay hover require the user's live acceptance.

Meeting translation has separate Apple and configured-language-model choices. Local speech stays resident; translation activates only for enabled meetings. Standard local Ollama uses native chat with thinking off and bounded output. See [local Whisper and meeting translation](live-local-whisper.md) for setup and performance considerations.

Real multiple-display placement, source/translation selection in a live meeting, long microphone sessions and paste/copy behavior remain user acceptance. Exact numbered-Space placement is not implemented; macOS controls fullscreen Space numbering. Windows and Linux are deferred at the user's explicit direction. Video remains paused.


## Readiness notification correction

Live inference timing callbacks previously re-showed Ready even though the model remained resident. A readiness-transition policy now ignores same-state callbacks without resetting the notification dismissal timer; real release/reload/failure transitions still notify. Two new tests cover repeated inference notifications and genuine reload/failure paths. All 152 tests in 35 suites passed. The packaged and installed bundles passed the native/notices/hash/signature audit, the fix was installed cleanly, and the app reopened idle. New build duplicates were moved to Trash. A repository check at the user's request confirmed this workspace has no Git repository and no agent-created commit history as of this checkpoint.


## Git tracking begins

At the user's request, this folder was initialized as a local Git repository on main. The current Mac source is the initial baseline; earlier work remains documented but has no recoverable commit-by-commit history. Downloaded models, builds/caches, recordings, libraries/vaults and device-local credentials/tooling are excluded. No remote was configured and no source was published. See version-control.md.


## Cortala branding checkpoint

The user confirmed Cortala, one word with the h. The public package/product, executable, app/menu/sidebar labels, icon asset and archive now use that spelling. Existing bundle/storage/Keychain/vault/CLI/sync identities remain compatible; source module paths also retain the legacy name. All 152 Swift tests and eight Python checks passed. The renamed release ZIP passed CRC and the package plus clean installed Cortala.app passed the native inventory, notices/hashes and signature audit. Native UI showed Cortala in the window, sidebar and app menu. The prior installed name and generated duplicate apps were preserved in Trash; personal data was not relocated. See branding.md.
