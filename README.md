# Clippy for macOS

A native macOS desktop assistant that lets people chat through their existing
Claude Code or Codex login, or use their own OpenAI/Anthropic API key.

## Features

- Claude Code subscription/login through the local `claude` CLI
- Codex subscription/login through the local `codex` CLI
- OpenAI and Anthropic API modes
- API keys stored in macOS Keychain
- Spoken replies and microphone dictation
- Original portfolio Clippy sprite artwork with context-aware animations
- Classic Office-style balloon above the floating character
- Inline compact replies that do not force open the full conversation
- Live provider-aware work stages, elapsed time, and accessible status announcements
- Compact questions receive short plain-text answers; full chat receives detailed Markdown
- Streamlined expanded-chat header with a smaller Clippy and clearer controls
- Compact action center for opening trusted apps and common folders
- Local Codex and Claude session discovery with explicit resume-in-Terminal actions
- Accessibility-powered “write here” requests that insert finished text into the last focused editable field
- Opt-in screen awareness that combines a live window capture with precise Accessibility control geometry
- Yellow “show me” highlights plus confirmed multi-step plans that can navigate, re-scan, find a field, and insert text
- Full step review before a plan runs; Send, Submit, payment, deletion, agreement, and password actions are blocked
- Secure fields are refused, and Clippy never presses Send or Submit on the user’s behalf
- Contextual answer actions for copying results and opening cited links
- Static message portraits and non-animated auto-scroll for smoother conversations
- True request cancellation for API calls and local Claude Code/Codex processes
- Calm completion, retry, and error-recovery states
- Explicit expand control for the complete chat window
- Compact-balloon attachments for images, PDFs, and text/code files
- Paste images or file URLs directly into compact or expanded chat with Command-V
- Portfolio-matched smooth sprite rendering and compact Segoe-style controls
- Persistent conversation history
- Optional always-on-top window
- Codex CLI runs in read-only mode

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

## Screen awareness

Enable both **Accessibility** and **Screen & System Audio Recording** in Clippy
Settings. Screen captures are created only after an explicit screen-help or
navigation request and are passed to the selected AI provider for analysis.
Clippy previews every multi-step action plan before running it and stops before
any final submission or sensitive control.
