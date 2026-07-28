<div align="center">
  <img src="Resources/ClippyIcon.png" width="140" alt="Clippy icon" />

  # Clippy for macOS

  **He's back. He can see your screen this time.**

  A native macOS desktop assistant — chat through your existing Claude Code
  or Codex login, or your own OpenAI/Anthropic API key — that can look at
  your screen, click, and type, with a paperclip's face on it.

  ![platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple)
  ![swift](https://img.shields.io/badge/swift-5.10-F05138?logo=swift&logoColor=white)
  ![universal](https://img.shields.io/badge/binary-Apple%20Silicon%20%2B%20Intel-blue)
</div>

<br>

<div align="center">
  <img src="Resources/ClippySprites.png" width="640" alt="Clippy sprite sheet" />
  <br>
  <sub>Every animation frame Clippy can strike — idle, thinking, talking, listening, success, alert.</sub>
</div>

## What it actually does

Clippy sits as a small floating character on your desktop. Ask it something
and it answers in a compact speech balloon, or open the full chat for longer
conversations, spoken replies, and file attachments — the classic assistant
experience, minus the 90s bugs.

The part that's new: when you ask it to *do* something on screen, it doesn't
just describe the steps back to you. It takes a screenshot, reads the
accessibility tree of whatever's in front of you, and acts:

- **Sees your screen on every request** — a fresh screenshot and an
  accessibility scan (control labels, roles, positions) go to the model with
  every message, so it can reason about what's actually in front of you
  instead of guessing.
- **Plans and re-plans, one step at a time** — Clippy doesn't build a
  10-step plan up front and run it blind. It runs one action, takes a new
  screenshot, and asks "given what just happened, what's next?" A screen
  rarely matches a prediction exactly — this is how Clippy notices.
- **Retries on its own** — a failed step (wrong label, a menu that opened
  somewhere else) triggers an automatic retry from a fresh screenshot,
  bounded to a few consecutive attempts before it stops and asks you.
- **Clicks and types by coordinate when labels can't be trusted** — browser
  address bars are the classic case: their accessibility label varies by
  version, and a page can have a look-alike search box with the exact same
  placeholder text sitting right next to the real one. Clippy can click the
  literal pixel it sees in the screenshot instead of gambling on a label
  match.
- **Aware of what's already open** — before launching a fresh app instance,
  it checks what's already running and prefers switching to it.
- **Shows its work** — every plan runs through a live checklist (✓ done,
  ✗ failed, • pending) and, once it finishes, gets posted to the chat
  transcript as a permanent record of what actually happened.

## Guardrails

- Every step is validated before it runs: **Send, Submit, publish, buy, pay,
  delete, accept/agree, sign out, and password/passcode controls are always
  refused** — this check is unconditional and independent of everything
  else below.
- Return is never sent by Clippy, with exactly one exception: submitting a
  browser's own address/search field (navigating to a URL or running a
  search). Every other field gets typed into but never submitted — you
  press Enter yourself.
- Secure/password fields are refused outright, regardless of what's asked.
- By default, this build's terminal/agent-CLI blocklist
  (`AutomationSafety.swift`) is **empty** — Clippy can click and type into
  Terminal, Warp, iTerm, and similar apps, on the reasoning that everything
  runs on your own machine and Return still can't be sent there. If you want
  that restricted again, add bundle identifiers / name fragments back to
  `blockedBundleIdentifiers` / `blockedNameFragments`.
- Nothing runs without both **Accessibility** and **Screen & System Audio
  Recording** permission granted in System Settings — Clippy prompts for
  both the first time it needs them.

## Build the DMG

Requirements: macOS 14+, Xcode command-line tools, and Swift 5.10+.

```bash
chmod +x scripts/build-dmg.sh
./scripts/build-dmg.sh
```

The output is written to `build/Clippy-macOS-universal.dmg`. The included app
runs natively on both Apple Silicon and Intel Macs.

All sprite, animation, and icon assets required by the packaging script are
included in `Resources`, so the repository builds independently of the
portfolio project it originated in.

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
network/file mutation disabled by the `read-only` sandbox.

### APIs

Select OpenAI API or Anthropic API in Settings, enter a model and API key, then
click **Save key**. Keys never enter app preferences; they are stored in the
user's macOS Keychain.

## Other features

- Spoken replies and microphone dictation
- Classic Office-style balloon above the floating character, with an expandable full chat window
- Live provider-aware work stages, elapsed time, and accessible status announcements
- Compact action center for opening trusted apps and common folders
- Local Codex and Claude session discovery with explicit resume-in-Terminal actions
- Contextual answer actions for copying results and opening cited links
- True request cancellation for API calls and local Claude Code/Codex processes
- Compact-balloon attachments for images, PDFs, and text/code files — paste images or file URLs directly with Command-V
- Persistent conversation history
- Optional always-on-top window
