# What this changes

<!-- One or two sentences. What behaviour is different after this merges? -->

## Why

<!-- The bug you hit, or the thing that was awkward. -->

## Checks

- [ ] `swift test` passes
- [ ] `swift run clippy-eval --offline` passes
- [ ] If `Resources/prismor-policy.yaml` changed, `./scripts/compile-policy.sh`
      was run and both files are committed

## Guardrails

- [ ] This does not let Clippy operate a control it previously refused

<!--
If it does, say which one and why, and add a fixture under
Sources/ClippyEval/Fixtures/ showing what still gets refused. Loosening a
refusal is a bigger change than it looks.
-->
