# Contributing

PRs welcome. This is a solo side project, so the bar is "does it work and can
I still read it in six months", not process.

## Getting set up

Requirements: macOS 14+, Xcode command-line tools, Swift 5.10+.

```bash
git clone https://github.com/Ar9av/clippy.git
cd clippy
swift build
swift test
```

To run the app from source rather than the DMG:

```bash
swift run Clippy
```

Accessibility and Screen Recording permissions are granted per binary, so a
`swift run` build and an installed `Clippy.app` are two different apps as far
as macOS is concerned. You will be asked to grant permissions again.

## Before you open a PR

```bash
swift test                       # unit tests
swift run clippy-eval --offline  # safety regression gate, no API key needed
```

CI runs both on every push and pull request, plus a check that the compiled
policy is in sync. If you touched `Resources/prismor-policy.yaml`, recompile
it and commit both files:

```bash
./scripts/compile-policy.sh
```

The app loads the JSON, not the YAML. CI fails the build if they have drifted,
because a policy edit that skipped the compile step would ship a guardrail
that silently doesn't match what the source of truth says.

## Changing the guardrails

`Sources/ClippyCore/AutomationSafety.swift` holds no rule text. Every refusal
comes from `Resources/prismor-policy.yaml`, so a change to what Clippy will
and won't touch should be a diff to that file, reviewable on its own.

Two things to keep in mind:

- **It fails closed on purpose.** A policy that is missing, corrupt, or
  contains a regex that won't compile makes Clippy treat every control as a
  final action and stop touching the screen. Don't add a fallback that
  degrades to "allow".
- **Loosening a rule needs a test.** Anything that lets Clippy operate a
  control it previously refused should come with a case in
  `Sources/ClippyEval/Fixtures/` showing what still gets refused.

## Style

Match the file you're in. Broadly: descriptive names over abbreviations, and
comments that explain *why* a thing is done rather than restating the code.
The codebase is small enough that an agent can read it in one pass, so if
you're using Claude Code or similar, pointing it at the whole repo works well.

## Reporting bugs

Screen automation failures are much easier to fix with the checklist output
from the chat transcript — Clippy posts every finished plan there with what
succeeded and what failed. Include it, along with your macOS version and which
provider you're using.

Security issues go to [SECURITY.md](SECURITY.md) instead of the issue tracker.
