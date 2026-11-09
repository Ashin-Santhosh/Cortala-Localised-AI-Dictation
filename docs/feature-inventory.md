# JustWisper feature inventory

Research date: 2026-10-21. This historical checklist covers macOS dictation features and possible accuracy benchmarks. The requirements are based on public vendor documentation. See [feature status](feature-status.md) for implementation and verification progress.

## Superwhisper checklist

| ID | Acceptance requirement | Documentation and boundary |
|---|---|---|
| SW-01 | [ ] Dictate into another application's focused text field. | [Introduction](https://superwhisper.com/docs/get-started/introduction). Actual supported applications and secure-field handling require runtime tests. |
| SW-02 | [ ] Select local or cloud speech recognition; allow independent optional text processing. | [AI models](https://superwhisper.com/models). Provider catalog and device requirements must be verified when implementing. |
| SW-03 | [ ] Unlimited modes, cloud recognition, AI modes, context, realtime, system audio, speaker separation, BYOK, and file transcription. | [Pro plan table](https://superwhisper.com/docs/billing/plans). These are Pro scope requirements; service entitlements and included provider billing are not transferable to JustWisper. |
| SW-04 | [ ] Built-in raw transcription, Message cleanup, Mail formatting/tone, Note structure, and context-aware Super equivalents; custom prompts. | [Built-in modes](https://superwhisper.com/docs/modes/built-in). Super uses active-app/input, selection, and recent clipboard context, including a documented three-second clipboard window; supports selected-text transformations. Local S1-mini is limited to Message/Mail. Exact prompt behavior remains unknown. |
| SW-05 | [ ] Mode switching from keyboard and menu bar; app/site activation rules; URL commands to select a mode, start/stop/toggle recording, and open settings. | [Switching modes](https://superwhisper.com/docs/modes/switching-modes). JustWisper needs its own URL scheme. |
| SW-06 | [ ] Toggle and hold-to-talk global shortcuts, per-mode shortcuts, recording feedback, microphone selection, permission onboarding, clipboard restoration. | [Changelog](https://superwhisper.com/changelog) documents shortcut and clipboard behavior. Exact UI, timing, conflict behavior, and defaults need installed-app observation. |
| SW-07 | [ ] Add vocabulary hints; deterministic case-insensitive replacements retaining configured output casing; CSV import; removal/editing. | [Vocabulary](https://superwhisper.com/docs/get-started/interface-vocabulary). Hints act during recognition; replacements act afterward. Avoid treating them as equivalent. |
| SW-08 | [ ] Save audio, raw transcript and processed output; search raw dictation; replay and reprocess using another mode; delete single/multiple entries; configurable retention and statistics. | [History](https://superwhisper.com/docs/get-started/history). Documented retention choices range from one day to forever. Meetings are separate from dictation history and stats in current docs. |
| SW-09 | [ ] Import audio/video from picker and Finder Open With; apply active mode; support MP3, MP4/MOV, and mono 16 kHz WAV. | [File transcription](https://superwhisper.com/docs/get-started/transcribe-files). Listed formats are documented recommendations, not an exhaustive decoder guarantee. |
| SW-10 | [ ] Multilingual recognition and translation to English. | [Introduction](https://superwhisper.com/docs/get-started/introduction), [plans](https://superwhisper.com/docs/billing/plans). Language quality and provider support need corpus tests. |
| SW-11 | [ ] Manage/download local models, select cloud models, configure BYOK connections and optional local text models. | [Models](https://superwhisper.com/models), [Pro plans](https://superwhisper.com/docs/billing/plans). Never assume access to Superwhisper's proprietary S1 services or cloud proxy. |
| SW-12 | [ ] macOS meetings: capture mic/system audio, live transcript, speaker labels, summaries and model selection; optional call detection and calendar reminders. | [Meetings](https://superwhisper.com/docs/meetings/overview). Documented for 3.0+, with local speaker separation. Calendar permission optional. Detection supports Zoom, Meet, Teams and Slack; other apps can start manually. This scope may exceed installed version. |
| SW-13 | [ ] Meeting summary templates, sharing and agent questions. | [Meetings overview](https://superwhisper.com/docs/meetings/overview) documents entry points; detailed output and integration behavior remain uninspected. |
| SW-14 | [ ] Local CLI/MCP operations for history, vocabulary and snippets; coding-agent integration. | [CLI announcement](https://superwhisper.com/blog/cli-mcp), [introduction](https://superwhisper.com/docs/get-started/introduction). Exact command/API compatibility is not established here. |
| SW-15 | [ ] Configuration export/backup and optional between-Mac configuration sync. | [Plans FAQ](https://superwhisper.com/docs/billing/plans) documents macOS Filesync and per-device default storage. Conflict handling remains unknown. |

Commercial support, licensing, hosted inference allowances and enterprise administration are separate service concerns. Functional parity does not provide free access to either vendor's servers. Public docs do not establish identical visual layout, hidden error states, or implementation details.

## Wispr Flow accuracy-related targets

These are behavior goals to evaluate, not evidence that a selected engine already matches Flow.

| ID | Candidate requirement | First-party source |
|---|---|---|
| WF-01 | [ ] Preserve names and technical vocabulary using context and personal dictionary. | [Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness) describes nearby text, app/site categories and proper nouns. |
| WF-02 | [ ] Cleanup fillers, punctuation and lists; honor spoken corrections without changing intended meaning. | [Features](https://wisprflow.ai/features) describes Backtrack and formatting. |
| WF-03 | [ ] Manual dictionary additions/corrections; optional learning from actual user edits. | [Dictionary](https://docs.wisprflow.ai/articles/4052411709-Teach-Flow-your-words-with-the-dictionary). Desktop auto-learning depends on its setting and an actual correction. |
| WF-04 | [ ] App-appropriate style, snippets, developer spelling and code formatting. | [Features](https://wisprflow.ai/features). Treat specialized IDE file tagging as separate integration work. |
| WF-05 | [ ] Exclude sensitive/numeric fields, browser address bars and placeholder text from context; clear per-dictation context when finished. | [Context Awareness](https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness). These are documented Flow boundaries, not verified JustWisper safeguards. |
| WF-06 | [ ] Test multilingual and network-recovery quality; distinguish missing microphone audio from processing failure. | [Accuracy and limitations](https://docs.wisprflow.ai/articles/4048537120). Flow uses cloud transcription and requires internet; accuracy varies by language and recording conditions. |

Flow's proprietary models, prompts, training data, exact audio pipeline and quality on this user's voice are unknown. A feature checklist or choice of Whisper alone cannot establish equivalent accuracy.

## Proposed accuracy evaluation

This protocol is a JustWisper design proposal, not a vendor claim.

1. Obtain a consented evaluation set from the user's actual languages and accent. Start with 50 short clips and 10 longer clips; include quiet/noisy rooms, laptop/headset microphones, names, dates, numbers, code terms, URLs, corrections, mixed languages and silence. Keep recordings and manually verified references together under explicit retention settings.
2. Maintain separate raw-speech and intended-final-text references. Raw ASR and AI cleanup solve different problems; filler removal should not be misreported as an ASR substitution error.
3. Compare JustWisper, the installed Superwhisper configuration, and Flow on the same audio where lawful replay/import is supported. Otherwise record matched utterances and disclose that microphone variations make the comparison weaker. Record app versions, models, settings, machine, audio hash and date.
4. Measure normalized word error rate (or character error rate where appropriate), proper-noun/number accuracy, omitted or invented facts, correction handling, first-word loss, silence hallucination, and end-of-speech-to-insertion latency at median and 95th percentile. Preserve unnormalized output too.
5. For polished output, measure meaning preservation and percentage accepted without edits. Blindly review outputs, track required edit count and critical semantic errors; cosmetic punctuation alone should not dominate the score.
6. Evaluate across native fields, web editors, IDEs, terminals, selected-text replacement, focus changes and denied permissions. Include cancellation, network failure, retries, long dictation and microphone disconnection.
7. Reserve at least 20% of clips as held-out data. Tune only on the development set. Repeat measured trials; report sample size and uncertainty. Claim Flow parity only after agreed thresholds pass on the held-out set, not from vendor marketing percentages.

Proposed release gate to confirm with the owner: no critical meaning changes on the held-out suite, name/number accuracy and no-edit acceptance at least as good as the measured Flow baseline, and a separately agreed latency budget. No absolute performance promise is supported yet.

## Remaining investigation

- [ ] Verify relevant behavior on supported versions of macOS.
- [ ] Evaluate a representative voice corpus before making comparative accuracy claims.
