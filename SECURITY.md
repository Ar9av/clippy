# Security

Clippy takes screenshots, reads the accessibility tree of whatever is in front
of you, and synthesises clicks and keystrokes. That is a large amount of trust
for a desktop app to ask for, so this file says what it does with it and how to
report it when something is wrong.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/Ar9av/clippy/security/advisories/new)
rather than a public issue.

Please include what an attacker gets, and the steps to reproduce it. It's a
side project maintained by one person — expect a reply within a week, not
within a day.

## What counts as a vulnerability here

The interesting class of bug in this app is **a way to make Clippy operate a
control it is supposed to refuse.** Specifically:

- Getting it to click Send, Submit, buy, pay, delete, agree, or sign out.
- Getting it to type into, or read back, a password or secure field.
- Getting the policy to load in a degraded state that allows actions instead
  of refusing them.
- Content on screen — a web page, an email, a document — steering Clippy into
  an action the user never asked for. Screen contents are treated as data, not
  as instructions, and a way around that is a bug worth reporting.

Also in scope: anything that exfiltrates API keys out of the Keychain, or the
stored chat history and memory, off the machine.

## What the app does with your data

- **Screenshots and accessibility scans** are sent to whichever provider you
  configured, for the request that needed them, and are not retained by the app
  afterwards. Requests that don't need the screen don't capture it.
- **API keys** live in the macOS Keychain, never in app preferences.
- **Chat history and memory** are stored locally in the app's support
  directory. Everything Clippy has remembered is listed verbatim in
  Settings ▸ *What Clippy remembers* and is deletable one line at a time.
- There is **no telemetry, no analytics, and no backend** operated by this
  project. Your traffic goes to your chosen model provider and nowhere else.

## Distribution

Releases are built by [GitHub Actions](.github/workflows/release.yml) from a
tagged commit, and the workflow runs the unit tests and the offline safety eval
before it packages anything.

The published DMG is ad-hoc signed and **not notarized**, which is why macOS
warns on first open. If that isn't a trade you want to make, build it yourself
with `./scripts/build-dmg.sh` — the output is byte-comparable in what it
contains, and you control the signature.
