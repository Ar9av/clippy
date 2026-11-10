# Changelog

Notable changes per release. Versions follow [semantic versioning](https://semver.org),
loosely — this is pre-1.0, so the minor number moves when behaviour changes.

## [Unreleased]

### Added

- **Clippy points at things.** Ask "where's the Appearance option?" or "show
  me how to turn on dark mode" and the character flies next to the target,
  gestures at it and rings it, one step at a time (up to four, about two
  seconds each, "1 of 3: …" captions), then flies home. Reduce Motion jumps
  instead of flying.
- **Pointing ids.** Screen Context now numbers every control (`C#`) and every
  line (`L#`) and word (`W#`) Vision OCR reads off the active display, plus
  what's under the mouse, so the model points by id, not by guessing a label.
  `[[CLIPPY_POINT_AT:x,y]]` covers things with no text. The approach is from
  [bluey-by-riley](https://github.com/rbrown101010/bluey-by-riley) (public
  domain). Thanks!

### Changed

- The OpenAI provider defaults to `gpt-5.6-luna` at low reasoning effort:
  about 1.7 s for a pointing reply, against 40+ s through the Codex CLI
  (most of which is the CLI timing out on a model-list refresh at startup).

### Fixed

- Pointing questions ("where", "which icon", "show me") now take a
  screenshot, and a reply asking for a "fresh screen" gets one and retries
  instead of being shown.
- A target Clippy couldn't find said "Visual guidance ready." It now says so.
- The highlight ring landed in the wrong place on a display that doesn't
  share the main display's top edge.
- Multi-step plans stopped after step 1 ("couldn't understand the model's
  next step"): the next step came back as bare JSON without its marker.
- Plan clicks could land on Clippy's own chat window (it sat over the target)
  or a row off in a dense list. Clippy now moves its windows beside the app
  before each step, and clicks snap to the on-screen text that matches the
  step's label.
- Before a click, Clippy raised whichever app had the top window anywhere on
  screen (say BlueStacks) instead of the app it was working in. It now raises
  that app, and if another app's window still covers the spot, it stops and
  says so instead of clicking into the wrong app.
- Steps that name a label the accessibility tree can't find (System
  Settings' sidebar rows) now fall back to the text read from the screenshot.
- Clippy no longer sees or points at its own windows in a screenshot.
- Captions on the highlight are sized to their text instead of cut off with
  "…".
- "Show me how…" / "where is…" now gets a pointing tour, not a click plan.

## [v0.2.1] — 2026-11-10

### Added

- **Pick your assistant.** All the classic Office characters (Clippy, Bonzi,
  Merlin, Links, Peedy, Rocky, Rover, Genie, Genius, F1), chosen in Settings.
- **Local Model provider** for any OpenAI-compatible server on your Mac
  (Ollama, LM Studio, llama.cpp). Nothing leaves the machine on that path.
- The Claude Code and Codex CLI providers can be pointed at a specific model.
- Customisable push-to-talk shortcuts and custom voice actions.

### Changed

- The chat window is compacted to Office-style proportions, with property
  sheet tabs and a Settings button in the title bar.

### Fixed

- The app reported version 2.0.0; the version is now stamped from the
  release tag at build time.
- Minimise did nothing (or sent Clippy to the Dock); it now collapses back to
  the floating character. Minimise and Close also forget a maximised window.
- Line breaks inside a reply were flattened in the full chat transcript.
- Restoring from maximised scrolled the transcript back to the oldest message.
- Typing in the chat field works again, and dictation no longer lands three
  times or leaves the listening sprite stuck.
- The title bar and balloon are no longer clipped off the top of the window.

## [v0.2.0] — 2026-08-09

### Added

- **A Windows 95 skin, in `RetroTheme.swift`.** Palette, bevels, and standard
  SwiftUI styles (`GroupBoxStyle`, `ButtonStyle`, `ToggleStyle`,
  `TextFieldStyle`) for the era's chrome, so a container adopts the whole look
  with `.retroDialog()` and the controls inside need no per-view changes.
  Applied to Settings and to the expanded chat window: title bars with a navy
  gradient, etched group boxes, square tick boxes, sunken text fields, a
  chunked progress bar, and a sunken status strip. Light mode is forced in
  those views — the palette is fixed 1995 values with no dark variant.

  The floating balloon, onboarding, and chat history are still unthemed.

- **The transcript is a sunken white well**, the way chat clients of the era
  framed their log. Messages previously floated on the window face with
  nothing containing them, which left the window looking unfinished and made
  a message scrolled under the toolbar look clipped rather than scrolled.
  Inside the well, Clippy's replies are plain text on the page and yours are
  grey panels — boxing both drew a border around white on white.

- **A real scrollbar on the transcript** — arrow buttons, a raised thumb, and
  the 50% checkerboard track the era drew by dithering white against the face
  colour. SwiftUI's own indicator can't be restyled, so this replaces it and
  reads its position from the scroll view's measured geometry. Without it,
  content scrolled under the top edge just vanished with nothing to explain
  where it went.

- One portrait per run of messages from the same side, and a message's Copy
  button only fades in under the pointer — a Copy button and a paperclip on
  every single line made the log hard to read.

- **Working title-bar buttons on the chat window.** Minimise collapses to the
  floating paperclip, maximise fills the current screen and restores to the
  exact frame you had, close goes back to the paperclip with its balloon
  dismissed. Maximise is implemented by hand rather than with
  `NSWindow.zoom(_:)`, which does nothing on this borderless, transparent
  window with its standard buttons hidden.

- The chat window's face is translucent over a blur of what's behind the
  window — the one deliberate anachronism, because a flat opaque slab of
  #C0C0C0 read as a screenshot pasted onto the desktop rather than a window
  sitting on it. It uses `NSVisualEffectView` in `.behindWindow` mode, not
  SwiftUI's `.ultraThinMaterial`: that blends within the window, so in a
  window whose own background is clear it has nothing to sample and renders
  as a flat wash indistinguishable from an opaque fill.

  Every surface of that window draws the same translucent face. A region that
  kept an opaque one didn't match — the translucent areas take their tone from
  whatever is behind them — and the join showed as a hard seam under the
  toolbar.

- **Parakeet v3 as a third dictation engine**, via
  [FluidAudio](https://github.com/FluidInference/FluidAudio). Runs on the
  Neural Engine, detects its own language, and is faster than Whisper.
  Settings ▸ Dictation is now an engine picker rather than a Whisper on/off
  toggle; an existing "use local Whisper" preference migrates to it.
- **Voice-activity gating on the local engines.** A Silero VAD trims silence
  before transcription, and a hold with no speech in it produces nothing at
  all instead of Whisper's hallucinated "Thank you." The onset, pre-roll and
  hangover values are [Handy](https://github.com/cjpais/Handy)'s
  (`SmoothedVad`) converted from 30 ms frame counts to durations.

### Fixed

- **Title-bar buttons rendered outside the title bar**, showing as grey tabs
  sticking up above the navy background.

  Two causes. `RetroButtonStyle` forces a 21pt minimum height while a 20pt bar
  with 2pt padding leaves 16pt, so the buttons were too tall — but the reason
  that was *visible* is that `RetroTitleBar` pinned itself with
  `.frame(height: 20)` and applied the gradient afterwards. A SwiftUI frame
  doesn't clip, so oversized content spilled past it while the background
  stayed 20pt. The buttons now use the compact metrics, and the bar sizes
  itself to its content instead of being pinned, which makes the failure
  impossible rather than merely unlikely. The window clips to its own frame
  too, so nothing can paint past the bevel onto the desktop.

### Changed

- **Local dictation records the whole hold and transcribes on release**,
  instead of streaming partial results. Releasing a streaming recogniser
  mid-utterance dropped whatever it hadn't committed; the old code slept
  250 ms after stopping and still clipped under load. That sleep now applies
  only to Apple's engine, which is still streaming and still the default.
- The mic button shows a spinner while a batch engine is transcribing, not
  just while a model is loading.

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
