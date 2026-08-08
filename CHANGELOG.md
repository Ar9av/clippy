# Changelog

Notable changes per release. Versions follow [semantic versioning](https://semver.org),
loosely — this is pre-1.0, so the minor number moves when behaviour changes.

## [v0.1.1] — 2026-08-08

### Fixed

- Typing goes into the field you asked for, on its own line, instead of
  overwriting the document you pointed it at.
- Closed two gaps in the form-field veto, which was previously a sentinel value
  the rest of the code didn't act on.
- Removed shared state between tests that caused a one-off failure, and stopped
  the test suite from deleting real chat history.

### Changed

- **Guardrails moved out of Swift and into a Prismor policy.**
  `AutomationSafety.swift` holds no rule text; it asks
  `Resources/prismor-policy.yaml` and reports the answer. Changing what Clippy
  will and won't touch is now a reviewable diff to one YAML file. It fails
  closed: a missing or uncompilable policy stops screen actions entirely.
- Subscribe joined the unconditional refusal list.

## [v0.1.0] — 2026-08-08

First release. Universal DMG, Apple Silicon and Intel.

### Added

- **Screen use.** Takes a screenshot, reads the accessibility tree, and
  operates the UI one step at a time — observe, act, verify — rather than
  running a plan built up front.
- **Reads control state, not just labels**, so it won't retype a field that
  already holds the right text or toggle a setting that was already on.
- Scrolling to find off-screen targets, with re-observation between ticks.
- Screenshot-coordinate fallback for when accessibility labels can't be
  trusted, such as browser address bars.
- Multi-display support: follows the screen holding the app you just switched
  to, and recovers if that display is unplugged.
- **Guardrails.** Send, submit, buy, pay, delete, agree, sign out, and password
  fields refused unconditionally. Return is never sent except to submit a
  browser's own address or search field.
- Memory that persists across chats and relaunches, listed verbatim and
  deletable line by line in Settings.
- Slash commands, custom prompts, and an editable balloon menu.
- Dictation with push-to-talk chords, including an optional local Whisper
  engine for offline transcription.
- Spoken replies, file and image attachments, and persistent chat history.
- `clippy-eval`, an offline regression harness that replays recorded screens as
  the safety gate.
- Providers: Claude Code, Codex, Anthropic API, OpenAI API. Keys in the
  macOS Keychain.

[v0.1.1]: https://github.com/Ar9av/clippy/releases/tag/v0.1.1
[v0.1.0]: https://github.com/Ar9av/clippy/releases/tag/v0.1.0
