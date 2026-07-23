#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
skill="$repo_root/skills/pps-skill"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/pps-skill-smoke.XXXXXX")"

cleanup() {
  case "$temp_root" in
    "${TMPDIR:-/tmp}"/pps-skill-smoke.*) rm -rf "$temp_root" ;;
    *) echo "Refusing unexpected cleanup target: $temp_root" >&2 ;;
  esac
}
trap cleanup EXIT

bash "$skill/scripts/init_project.sh" standard-case \
  --profile standard --parent "$temp_root" --no-git
bash "$skill/scripts/init_project.sh" evidence-case \
  --profile evidence --parent "$temp_root" --no-git

bash "$temp_root/standard-case/scripts/status_check.sh" \
  --root "$temp_root/standard-case"
bash "$temp_root/evidence-case/scripts/validate_project.sh" \
  "$temp_root/evidence-case"

[[ -f "$temp_root/evidence-case/SOURCE_INDEX.md" ]]
[[ -f "$temp_root/evidence-case/docs/CURRENT_REVIEW_EVIDENCE.md" ]]

cp -R "$temp_root/standard-case" "$temp_root/missing-coverage"
sed -i '/^| M-002 |/d' "$temp_root/missing-coverage/CONTEXT.md"
if bash "$temp_root/missing-coverage/scripts/validate_project.sh" \
  "$temp_root/missing-coverage" >"$temp_root/missing.out" 2>&1; then
  echo "Missing coverage was incorrectly accepted." >&2
  exit 1
fi
grep -q "Manifest ID M-002 has no row" "$temp_root/missing.out"

cp -R "$temp_root/standard-case" "$temp_root/inactive-decision"
sed -i 's/^- Decisions: none$/- Decisions: D-404/' \
  "$temp_root/inactive-decision/CONTEXT.md"
if bash "$temp_root/inactive-decision/scripts/validate_project.sh" \
  "$temp_root/inactive-decision" >"$temp_root/inactive.out" 2>&1; then
  echo "Inactive manifest decision was incorrectly accepted." >&2
  exit 1
fi
grep -q "Manifest ID D-404 must appear exactly once" "$temp_root/inactive.out"

echo "PPS Bash smoke tests: OK"
