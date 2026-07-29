<div align="center">
  <img src="Resources/ClippyIcon.png" width="140" alt="Clippy icon" />

  # Clippy for macOS

  **A native macOS desktop assistant that can actually see your screen and act on it.**

  Chat through your existing Claude Code or Codex login, or bring your own
  OpenAI or Anthropic API key. Ask it to do something on screen and it takes
  a screenshot, reads the accessibility tree of whatever is in front of you,
  and acts, instead of just describing the steps back to you.

  ![platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple)
  ![swift](https://img.shields.io/badge/swift-5.10-F05138?logo=swift&logoColor=white)
  ![universal](https://img.shields.io/badge/binary-Apple%20Silicon%20%2B%20Intel-blue)
</div>

## About

Most "AI desktop assistant" demos stop at chat: you ask a question, it
answers, and you still do the clicking yourself. This project started from
wanting something that could actually reach into the app in front of me,
click the right control, type into the right field, and know when to stop
and ask instead of guessing.

The name and the paperclip are a nod to Microsoft's old Office Assistant.
Everything else, the screen reasoning, the safety checks, the retry logic,
is original.

It's a solo side project, developed and rebuilt in public commits as bugs
turned up from actually using it day to day. Most of the interesting work
is in getting the automation to fail safely: a step that can't find its
target should stop and ask, not click something at random.

## What it actually does

Clippy sits as a small floating character on your desktop. Ask it something
and it answers in a compact speech balloon, or open the full chat for longer
conversations, spoken replies, and file attachments: the classic assistant
experience, minus the 90s bugs.

The part that's new: when you ask it to *do* something on screen, it doesn't
just describe the steps back to you. It takes a screenshot, reads the
accessibility tree of whatever's in front of you, and acts:

- **Sees your screen on every request.** A fresh screenshot and an
  accessibility scan (control labels, roles, positions) go to the model with
  every message, so it can reason about what's actually in front of you
  instead of guessing.
- **Plans and re-plans, one step at a time.** Clippy doesn't build a
  10-step plan up front and run it blind. It runs one action, takes a new
  screenshot, and asks "given what just happened, what's next?" A screen
  rarely matches a prediction exactly, and this is how Clippy notices.
- **Retries on its own.** A failed step (wrong label, a menu that opened
  somewhere else) triggers an automatic retry from a fresh screenshot,
  bounded to a few consecutive attempts before it stops and asks you.
- **Clicks and types by coordinate when labels can't be trusted.** Browser
  address bars are the classic case: their accessibility label varies by
  version, and a page can have a look-alike search box with the exact same
  placeholder text sitting right next to the real one. Clippy can click the
  literal pixel it sees in the screenshot instead of gambling on a label
  match.
- **Aware of what's already open.** Before launching a fresh app instance,
  it checks what's already running and prefers switching to it.
- **Shows its work.** Every plan runs through a live checklist (✓ done,
  ✗ failed, • pending) and, once it finishes, gets posted to the chat
  transcript as a permanent record of what actually happened.

## Project structure

```
Sources/
  ClippyCore/                    Shared library: providers, prompts, safety. No UI, no AppKit.
    AIService.swift              Provider-agnostic prompt building and response marker parsing.
    AnthropicClient.swift        Real Anthropic tool-use client with streaming.
    Models.swift                 ChatMessage, ScreenPlanStep, PendingScreenPlan, and friends.
    ScreenPlanRunner.swift       Runs a validated plan step by step against ScreenStepPerforming.
    ScreenAgent.swift            Observe, act, verify loop for tool-use screen intent.
    AIProviding.swift            AIProviding protocol plus the CLI-backed and API-backed providers.
    ClippyTools.swift            Tool-use schema definitions for model-driven screen actions.
    ScreenTypes.swift            ScreenContext, ScreenElementSummary, and screenshot metadata.
    AutomationSafety.swift       Final-action refusal list: send, submit, pay, delete, and so on.
    CoordinateSpace.swift        Shared math for correcting model-supplied screen points.
    KeychainStore.swift          API key storage.
    SystemPrompt.swift           Shared system prompt text.

  ClippyMac/                     The app: SwiftUI, AppKit, macOS Accessibility.
    ContentView.swift            The floating balloon, expanded chat window, and Settings.
    ScreenAwarenessService.swift Accessibility-tree scanning, clicking, and typing.
    ChatViewModel.swift          Central state machine driving every request and screen action.
    ScreenTypingService.swift    Live-tracks the last focused editable field for direct insertion.
    LocalActionService.swift     Discovers local Claude Code and Codex sessions to resume.
    ClippyMacApp.swift           App entry point, window configuration, permissions bootstrap.
    ChatStore.swift              Conversation, history, and pending-plan persistence.
    SpeechService.swift          Dictation and spoken replies, including the optional local Whisper engine.
    ListeningIndicatorView.swift Animated waveform and pulse shown while dictation is listening.
    PushToTalkMonitor.swift      Hold-⌘⌥ push-to-talk chord tracking.
    OnboardingView.swift         First-run permissions primer.
    PermissionsModel.swift       Live Accessibility and Screen Recording permission state.
    ClippySpriteView.swift       Sprite-sheet animation and the floating character's on-screen look.

  ClippyEval/                    Offline regression harness for the tool-use screen-intent path.

Tests/ClippyMacTests/            Unit tests: plan running, tool-use parsing, safety, persistence.
scripts/build-dmg.sh             Universal-binary build, code signing, and DMG packaging.
```

## Guardrails

- Every step is validated before it runs: **Send, Submit, publish, buy, pay,
  delete, accept or agree, sign out, and password or passcode controls are
  always refused.** This check is unconditional and independent of
  everything else below.
- Return is never sent by Clippy, with exactly one exception: submitting a
  browser's own address or search field (navigating to a URL or running a
  search). Every other field gets typed into but never submitted; you press
  Enter yourself.
- Secure and password fields are refused outright, regardless of what's
  asked.
- By default, this build's terminal and agent-CLI blocklist
  (`AutomationSafety.swift`) is **empty**: Clippy can click and type into
  Terminal, Warp, iTerm, and similar apps, on the reasoning that everything
  runs on your own machine and Return still can't be sent there. If you want
  that restricted again, add bundle identifiers or name fragments back to
  `blockedBundleIdentifiers` and `blockedNameFragments`.
- Nothing runs without both **Accessibility** and **Screen & System Audio
  Recording** permission granted in System Settings. Clippy prompts for both
  the first time it needs them.

## Build the DMG

Requirements: macOS 14+, Xcode command-line tools, and Swift 5.10+.

```bash
chmod +x scripts/build-dmg.sh
./scripts/build-dmg.sh
```

The output is written to `build/Clippy-macOS-universal.dmg`. The included app
runs natively on both Apple Silicon and Intel Macs.

Local builds automatically use the first Apple Development code-signing
identity in the current keychain. This keeps macOS Accessibility permission
stable across rebuilds. If no development identity is available, the script
falls back to ad-hoc signing.

For public distribution without Gatekeeper warnings, set a Developer ID
identity before building:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-dmg.sh
```

Then notarize the resulting DMG with your Apple Developer credentials and
staple the ticket.

Run the test suite with:

```bash
swift test
```

## Provider setup

### Claude Code

Install Claude Code and authenticate once in Terminal. Clippy finds common
Homebrew, npm, and user-local install locations and runs `claude -p`.

### Codex

Install Codex and authenticate once in Terminal. Clippy runs `codex exec` with
network and file mutation disabled by the `read-only` sandbox.

### APIs

Select OpenAI API or Anthropic API in Settings, enter a model and API key, then
click **Save key**. Keys never enter app preferences; they are stored in the
user's macOS Keychain.

## Other features

- Spoken replies and microphone dictation, with an optional local Whisper
  engine (inspired by [OpenWhispr](https://github.com/OpenWhispr/openwhispr))
  for more accurate, fully offline transcription — off by default, offered
  once at first launch and toggleable any time in Settings
- **Push-to-talk dictation — hold a chord to speak, release to stop.** Two
  destinations:
  - **Hold ⌘⌥** to type into whatever editable field you had focused. If
    there's nowhere safe to put it — no editable target, or a password
    field, which is always refused — it lands on your clipboard instead and
    Clippy says so. Held while Clippy itself is frontmost, it fills Clippy's
    composer rather than another app.
  - **Hold ⌥⇧** to send what you said to Clippy as a chat message.

  Both work from any app (needs Accessibility; otherwise only while Clippy
  is frontmost). Pressing any key mid-hold cancels the recording, so the
  chords stay usable as ordinary typing modifiers. Edit ▸ Toggle Dictation
  is the hands-free alternative.
- Classic Office-style balloon above the floating character, with an expandable full chat window
- Live provider-aware work stages, elapsed time, and accessible status announcements
- Compact action center for opening trusted apps and common folders
- Local Codex and Claude session discovery with explicit resume-in-Terminal actions
- Contextual answer actions for copying results and opening cited links
- True request cancellation for API calls and local Claude Code/Codex processes
- Compact-balloon attachments for images, PDFs, and text/code files: paste images or file URLs directly with Command-V
- Persistent conversation history
- Optional always-on-top window

## Contributing

PRs welcome. If you're using Claude Code or a similar agent, it can read this
whole codebase in one pass; just point it at what you want changed.
