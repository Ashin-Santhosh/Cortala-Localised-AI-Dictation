# JustWisper implementation plan

Planning review: 2026-10-21. This document is a source review and implementation plan, not a claim that the app builds or that its behaviors have passed runtime tests. Requirement IDs refer to [feature-inventory.md](feature-inventory.md). The working directory is not currently a Git repository, so there is no commit/diff baseline for this review.


## Current extension checkpoint — 2026-10-21

Daily-use source now connects CSV vocabulary editing/import/export, snippets, history statistics, raw-text reformatting, configurable shortcuts, app/site matching, opt-in context/selection transformations, login launch, device selection, provisional dictation captions, provider presets, model downloads, chunked transcription/timestamps, meeting templates/questions, Calendar suggestions and local automation. These controls are functional paths, with automated checks and live acceptance tracked separately in `status.md`.

Manual configuration folder exchange has a versioned snapshot and explicit conflict policy: Push/Pull only; keys/history/audio omitted; a changed or unreviewed shared file yields a separate local conflict copy; accepted replacements preserve previous shared data; Pull backs up local data and retains machine-specific privacy/access settings. It does not claim background or hosted sync.

The unchecked acceptance rows below remain gates even when corresponding source exists. In particular, real permission flows, target/selection changes, device disconnection, large downloads/cancellation, real calls, cloud credentials, user-voice accuracy and cross-machine distribution cannot be inferred from a build. True streaming, meeting captions, evaluated diarization, active-call inference, learning from edits, independent per-mode endpoint/credential routes and signed/notarized distribution still need implementation or external inputs.


## Product commitment and evidence

Build a native macOS app with independently selectable local/cloud speech recognition and optional local/cloud text processing. English is the initial quality focus; multilingual recognition and English translation remain explicit requirements. Personal use comes first; freely distributable packaging follows. Superwhisper 3.0.2 is the observed feature baseline. Wispr Flow accuracy is a measurable target, not a property established by using Whisper or adding a cleanup prompt.

For local transcription, select a compatible Whisper runtime and validate the downloaded model. Cloud inference requires a configured provider endpoint and credentials. Track documented behavior, source implementation, runtime observations and measured accuracy separately.

The first milestone is a working daily dictation path. It is a milestone toward full parity, not a reduction of the requested scope. The current code is a scaffold: system audio is an isolated service, meetings use only microphone recording, and many parity features remain absent.

## Current code assessment

Present in source, not yet validated end to end:

- SwiftUI window and menu bar, fixed toggle/hold shortcuts, microphone WAV capture and level overlay.
- Local `whisper-cli` and an OpenAI-compatible multipart transcription endpoint; independent chat-completions rewriting; Keychain storage.
- Built-in/custom modes, app bundle matching, vocabulary prompting and replacements.
- JSON history/configuration, transcript export, file import, raw transcript saved before optional rewriting.
- Clipboard restoration guarded by change count; HTTP endpoint validation; local child process cancellation/timeout; WER calculator.
- ScreenCaptureKit system-audio recording service, currently unused by AppStore.

Existing tests cover endpoint validation, invalid executable and unknown provider. They do not establish a working audio, model, paste, meeting or recovery path. Build success is blocked by the reported toolchain/SwiftPM manifest mismatch; the project-local module-map overlay addresses only the earlier duplicate SwiftBridging problem.

## Fixes before expanding scope

| Priority | Finding and trigger | Required result |
|---|---|---|
| P0 | Build cannot currently be reproduced. | Resolve coherent Swift compiler, manifest library, SDK and linker selection without editing the installed toolchain. Build and test scripts must run from a clean project-local cache and produce an app bundle. Capture actual failures and final commands. |
| P1 | `DesktopIntegration.captureTarget` returns without clearing its previous target when JustWisper is frontmost. Starting from Home after a previous dictation can paste into that earlier app. | Snapshot destination per operation; clear invalid targets. Recording started in the app must use an explicit destination or default to review/copy. Never silently reuse a stale target. |
| P1 | Paste remembers only an application, then reactivates it after ASR. A changed field/window can receive the result. | Capture focused Accessibility element and selection where available, verify it is still an eligible destination, reject secure/nontext fields, and fall back to copy/review when the original destination cannot be validated. Record delivery outcome separately from transcription success. |
| P1 | Failed library decoding leaves defaults in memory; a later save can overwrite the existing file despite the error text promising otherwise. | Version the persisted schema, decode defaults for newly introduced keys, preserve the unreadable original, and require a successful recovery/migration or explicit reset before replacement. Persist errors visibly. |
| P1 | Hold-start is ignored while busy, but hold-release still stops any current recording. | Track which input gesture owns recording. Releasing an ignored hold must not stop a toggle recording or meeting. Test first-run permission delay and quick press/release. |
| P1 | Local import accepts movies in the picker but conversion opens them as `AVAudioFile`. | Extract an audio track with AVAssetReader or equivalent for supported movie containers. Report unsupported/no-audio files precisely; validate MP3, M4A, WAV, MP4 and MOV fixtures. |
| P1 | `retentionDays` exists but is unused; no history deletion, audio replay or reprocess action exists. Failed capture files can remain outside discoverable history. | Add managed recording storage, recoverable processing states, retry/rewrite-only actions, replay, deletion and retention enforcement. Make retained failed audio visible and removable. |
| P2 | Detached audio conversion does not inherit parent cancellation, so cancellation checks inside the detached task do not stop conversion. | Explicitly cancel and await the conversion worker; avoid deleting its working files until it finishes. Cancellation must leave no active child/worker and no late result. |
| P2 | Local child cleanup sleeps in an already-cancelled task and therefore may skip the intended grace period; SIGKILL is not followed by confirmed process exit. | Use cancellation-independent termination/reaping and await child exit before removing temporary output. Test a deliberately slow child process. |
| P2 | `save()` catches errors without signaling failure to the pipeline, which can still delete audio and claim completion. | Make durable save success explicit; retain recovery audio until transcript persistence is confirmed. |
| P2 | A long meeting is one request; cloud body loads the whole file and a fixed 100 MB cap does not match every provider. | Add provider capabilities/limits, chunk long audio with overlap, reconcile boundaries, and retain timestamps. Avoid an unrestricted full-file memory copy for long uploads. |
| P2 | Vocabulary replacements run sequentially, so one replacement can match a later source phrase. | Define collision policy and apply replacements once against original spans, longest match first. Include Unicode boundaries, casing and overlapping terms. |
| P2 | Hotkey conflict errors are stored but not displayed; shortcuts are fixed. Language/retention/login properties are not all represented by working UI. | Expose actionable shortcut errors and configuration; either implement each visible control or clearly identify unavailable behavior. |

## Delivery stages and acceptance checklist

### Stage 0 — Reproducible native app

- [ ] `scripts/build.sh` creates a launchable `dist/JustWisper.app` with the expected executable, bundle ID, permission strings and version.
- [ ] `scripts/test.sh` runs the relevant tests using the same toolchain selection as the build.
- [ ] Run the bundle, inspect the actual UI, and verify permission prompts identify JustWisper.
- [ ] Document toolchain versions and project-local workarounds; no system compiler files are edited.
- [ ] Preserve existing local source and settings before schema migration or packaging changes.

### Stage 1 — Complete personal dictation loop (SW-01, 02, 04, 06, 10, 11)

- [ ] Provision and verify the approved model; save the executable/model paths; show missing/incomplete model errors before recording.
- [ ] Run a known speech fixture through local recognition and confirm nonempty expected output. Benchmark model load and transcription latency on this Mac.
- [ ] Record from the default microphone; meter responds; first word and last word survive; stop and cancellation have distinct outcomes.
- [ ] Toggle and hold work from another app; hold release during permission startup cancels cleanly; ignored gestures cannot stop unrelated recording.
- [ ] Recording in JustWisper produces reviewable output without sending it to a stale app.
- [ ] Dictation started in a supported external field reaches the same eligible destination exactly once. Native TextEdit, browser textarea/contenteditable and an editor are minimum manual checks. Terminal delivery requires deliberate testing, including multiline text.
- [ ] Clipboard restoration preserves all previously available types and does not overwrite a newer user copy.
- [ ] Denied microphone/Accessibility permissions, destination closure/focus change, empty/silent audio, invalid model, cancellation and quit have clear recoverable outcomes.
- [ ] Raw transcription mode is useful without configuring a language model. Cleanup modes preserve raw text and expose a retry/fallback when rewriting fails.
- [ ] Cloud transcription and rewriting each support successful requests and handled 401/413/429/5xx/timeout/malformed-response cases. Mock tests establish protocol behavior; a live credentialed test is still needed before calling cloud integration verified.
- [ ] UI displays the effective speech route and text route. Local ASR plus remote rewriting must not be labeled wholly on-device.
- [ ] English, automatic language detection, an explicitly selected second language and translate-to-English are exercised. Translation must not silently become ordinary transcription when a model is unavailable.

### Stage 2 — Daily workflow and storage completeness (SW-04–11, 15)

- [ ] Versioned settings migration, atomic writes and recovery from malformed/truncated library files.
- [ ] Search raw and processed text; view raw/processed output; replay audio; retry ASR; rerun another mode from saved raw text; copy/export; delete one/many entries.
- [ ] Configurable retention removes matching records and owned audio while preserving unrelated imported originals. Failed jobs appear in recovery UI and follow an explicit retention policy.
- [ ] Vocabulary add/edit/delete and properly quoted CSV import/export; recognition hints and deterministic replacements remain distinct.
- [ ] Per-mode speech/text model overrides, language, formatting/tone, custom instructions, output behavior, app/site rules and shortcuts.
- [ ] Per-mode model ID/local-path overrides and editable toggle/hold/per-mode shortcuts with conflict reporting; selectable microphone and device-disconnection recovery; login launch and sound feedback.
- [ ] Model library with progress, cancellation, resume or clean restart, disk-space checks, checksum verification, installed status and removal. Large model work must not freeze the UI.
- [ ] Audio/video import via picker and Finder Open With; long-file progress, cancellation and duration metadata.
- [ ] `justwisper://` commands actually route select/start/stop/toggle/settings actions with validated parameters; declaring the URL scheme alone is insufficient.
- [ ] Export/import settings and vocabulary round-trip without keys/history; configuration sync has a documented conflict policy before it is enabled.

### Stage 3 — Context and realtime dictation (SW-03–05, WF-01–05)

- [ ] Opt-in app/site, nearby text and selected-text context capture, with explicit sensitive-field exclusions and bounded per-job lifetime.
- [ ] Selected-text transformations preserve the selection target until the result is ready; an invalidated target prompts review.
- [ ] App-appropriate style and snippets, spoken correction handling and optional learning from actual edits have visible controls and reproducible examples.
- [ ] Realtime transcript is clearly provisional; finalization reconciles chunk overlap and never pastes repeated partial text.
- [ ] Offline operation exercises local speech plus local rewriting; provider failures never cause an undisclosed route switch.

### Stage 4 — Full meetings (SW-12, 13)

- [ ] Integrate existing system-audio service with selectable microphone/system/both sources, correct permission copy and recovery from stream failure.
- [ ] Record mic/system on a common timeline, handle sample-rate conversion, prevent duplicate playback/feedback, and test a real call with consenting participants.
- [ ] Long-session chunked transcription, timestamps and resumable storage survive interruption; live transcript and final transcript agree after reconciliation.
- [ ] Speaker separation is implemented and evaluated; labels are not invented by the summary model. Separate mic/system tracks alone do not identify every remote speaker.
- [ ] Meeting search/playback, summaries/templates, decisions/action items, transcript-grounded questions and user-triggered sharing/export.
- [ ] Optional call detection and calendar reminders are separately permissioned and tested for supported apps, with a manual start fallback.

### Stage 5 — Integrations and free distribution (SW-14, 15)

- [ ] Documented CLI/MCP for history, vocabulary and snippets; deterministic command tests; no proprietary API compatibility claim without verification.
- [ ] Stable package, reproducible build instructions, model/runtime licenses and notices; choose bundled or user-installed local runtime explicitly.
- [ ] Test outside the development machine, including the minimum macOS version and each advertised CPU architecture. Current Homebrew paths are not portable distribution dependencies.
- [ ] Sign/notarize the distribution build when the required developer identity is available; distinguish personal ad-hoc signing from public distribution readiness.
- [ ] Include data-storage/retention/provider information and backup/restore instructions; verify uninstall leaves no unexpected running helper.
- [ ] Reconcile every inventory row with observed acceptance evidence. Full parity is complete only when the remaining rows pass or the user explicitly revises scope.

## Accuracy evaluation and release claims

Implement a repeatable fixture runner before tuning prompts. Use synthetic or licensed fixtures for pipeline smoke tests; they cannot establish quality on the user's accent. A user-voice corpus and comparable Flow output are required for the requested accuracy claim.

1. Start with 50 short and 10 longer consented clips, and reserve at least 20% before tuning. Record audio hashes, durations, environment/microphone, language, user-verified raw reference and intended final reference. Include silence, noise, names, numbers, technical terms, dates, URLs, lists and spoken corrections.
2. Evaluate local ASR, cloud ASR, local rewrite and cloud rewrite as separate configurations. Save model/runtime versions, settings, vocabulary, prompts and latency per run. Report failed/cancelled jobs rather than excluding them from the score.
3. Measure normalized WER for English and suitable CER/tokenization for other languages; retain unnormalized outputs. Score names/numbers, missing/invented facts, first/last-word loss and silence hallucination separately. WER alone does not measure polished-output usefulness.
4. Compare meaning preservation, edit count and no-edit acceptance using blinded review of final outputs. Do not score intentional filler removal as a recognition error by using the wrong reference.
5. Run installed Flow/Superwhisper on identical clips if supported, otherwise disclose the weaker matched-utterance comparison and microphone differences. Record versions and settings. No Pro entitlement is needed to label unavailable baselines honestly.
6. Report median/p95 end-of-speech-to-insertion latency, including model startup, ASR, rewriting and delivery. Set a latency budget from this machine's measurements rather than inventing a universal guarantee.

Provisional quality gate: no critical meaning changes on the held-out suite, and name/number accuracy plus no-edit acceptance at least as good as the measured Flow baseline. Report sample size and uncertainty. Without that baseline, the accurate label is **accuracy not yet established**, even if dictation works well in a demo.

## Code ownership and immediate assignments

The planning role reviews architecture, acceptance evidence and parity scope. The implementation role writes and validates Swift. Keep source-file ownership clear while work is concurrent; do not add another framework or rewrite the scaffold before stabilizing its working paths.

1. **Build/package owner:** `scripts/`, `Package.swift`, bundle setup. Resolve Stage 0 and report exact commands and artifacts. Coordinate this first because it gates all runtime evidence.
2. **Core workflow owner:** `AppStore.swift`, `Models.swift`, `DesktopServices.swift`. Fix destination/session ownership, schema recovery, durable saves, gesture ownership and recovery/history operations. Prefer an explicit recording/processing state enum and immutable per-job configuration over expanding loosely coupled booleans.
3. **Audio/provider owner:** `AudioServices.swift`, `ProviderServices.swift`. Validate approved local model, conversion, cancellation, nonempty/silent output behavior and provider limits. Introduce injectable provider/process boundaries where necessary for meaningful failure tests.
4. **UI/integration owner:** `JustWisperApp.swift`, bundle handlers. Connect proven services, surface actionable errors/status, complete history/provider controls and perform the native-app smoke matrix. Meetings expansion follows the core loop; do not present disconnected services as working features.

Immediate implementation sequence: build → provision model → one fixture through local ASR → reliable microphone/target/paste loop → storage/recovery and regression checks → provider validation → progressive parity stages → measured accuracy. Finish each stage with a short evidence record of what ran, what passed and what remains unverified.
