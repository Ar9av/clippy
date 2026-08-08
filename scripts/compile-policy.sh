#!/bin/zsh
# Compiles the Prismor policy YAML that defines Clippy's guardrail into the
# JSON the app actually loads.
#
# Swift has no YAML parser in this package and adding a dependency to the one
# component that must never fail to load would be the wrong trade. JSON is in
# the standard library, so the policy is authored in Warden's YAML format and
# compiled here. Both files are checked in; CI re-runs this and fails if the
# JSON is stale, so they cannot drift.
#
# This step is exactly what a `prismor policy export --json` would remove —
# see the integration notes in the README.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE="$PROJECT_DIR/Resources/prismor-policy.yaml"
OUTPUT="$PROJECT_DIR/Sources/ClippyCore/Resources/prismor-policy.json"

mkdir -p "${OUTPUT:h}"

python3 - "$SOURCE" "$OUTPUT" <<'PY'
import json, sys

try:
    import yaml
except ImportError:
    sys.exit("error: PyYAML is required (pip3 install pyyaml), or run this inside the prismor venv")

source, output = sys.argv[1], sys.argv[2]
with open(source) as handle:
    policy = yaml.safe_load(handle)

for key in ("version", "rules"):
    if key not in policy:
        sys.exit(f"error: policy is missing required key '{key}'")

for rule in policy["rules"]:
    for key in ("id", "severity", "category", "title", "event_types", "patterns", "action"):
        if key not in rule:
            sys.exit(f"error: rule '{rule.get('id', '?')}' is missing required key '{key}'")
    if not rule["patterns"]:
        sys.exit(f"error: rule '{rule['id']}' has no patterns")

with open(output, "w") as handle:
    json.dump(policy, handle, indent=2, sort_keys=True)
    handle.write("\n")

enabled = sum(1 for rule in policy["rules"] if rule.get("enabled", True))
print(f"{output}: {enabled} enabled rule(s), {len(policy.get('allowlists', []))} allowlist entr(ies)")
PY
