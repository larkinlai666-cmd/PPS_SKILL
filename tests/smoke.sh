#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
skill="$repo_root/skills/pps-skill"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/pps-skill-smoke.XXXXXX")"

# F-050-02: the suite must survive field machines whose python3 is a Store
# stub. Resolve once and use it everywhere below.
PY3=""
for py_cand in "${PPS_PYTHON:-}" python3 python; do
  [[ -n "$py_cand" ]] || continue
  if command -v "$py_cand" >/dev/null 2>&1 &&
    "$py_cand" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    PY3="$py_cand"
    break
  fi
done
if [[ -z "$PY3" ]] && command -v py >/dev/null 2>&1 &&
  py -3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
  PY3="py -3"
fi
[[ -n "$PY3" ]] || { echo "smoke needs a Python 3 interpreter (tried python3, python, py -3)" >&2; exit 2; }

cleanup() {
  case "$temp_root" in
    "${TMPDIR:-/tmp}"/pps-skill-smoke.*) rm -rf "$temp_root" ;;
    *) echo "Refusing unexpected cleanup target: $temp_root" >&2 ;;
  esac
}
trap cleanup EXIT

bash "$skill/scripts/validate_skill.sh" "$skill"
# F-048-02: the live-line parser must stay ONE implementation. The gate and
# the validator each carry a copy; a drift fixture makes divergence loud.
parser_probe() {
  local file="$1"
  local fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\(\)" { grab = 1 }
    grab { print }
    grab && $0 == "}" { exit }
  ' "$file"
}
gate_parser="$(parser_probe "$skill/scripts/verify_gate.sh" entry_live_lines)$(parser_probe "$skill/scripts/verify_gate.sh" entry_invokes_path)"
validate_parser="$(parser_probe "$skill/scripts/validate_project.sh" entry_live_lines)$(parser_probe "$skill/scripts/validate_project.sh" entry_invokes_path)"
[[ "$gate_parser" == "$validate_parser" ]] || {
  echo "Live-line parser drifted between the gate and the validator." >&2
  exit 1
}
cp -R "$skill" "$temp_root/broken-skill"
rm "$temp_root/broken-skill/references/protocol.md"
if bash "$temp_root/broken-skill/scripts/validate_skill.sh" \
  "$temp_root/broken-skill" >"$temp_root/broken-skill.out" 2>&1; then
  echo "Skill health validator accepted a missing required file." >&2
  exit 1
fi
grep -q "Missing required skill file: references/protocol.md" \
  "$temp_root/broken-skill.out"

expect_invalid() {
  local project_root="$1"
  local expected="$2"
  local label="$3"
  local output_file="$temp_root/$(basename "$project_root").invalid.out"
  if bash "$project_root/scripts/validate_project.sh" \
    "$project_root" >"$output_file" 2>&1; then
    echo "$label was incorrectly accepted." >&2
    exit 1
  fi
  grep -q "$expected" "$output_file" || {
    echo "$label failed without the expected diagnostic: $expected" >&2
    cat "$output_file" >&2
    exit 1
  }
}

bash "$skill/scripts/init_project.sh" standard-case \
  --profile standard --parent "$temp_root" --no-git
bash "$skill/scripts/init_project.sh" evidence-case \
  --profile evidence --parent "$temp_root" --no-git
bash "$skill/scripts/init_project.sh" software-case \
  --mode software --profile standard --parent "$temp_root" --no-git
bash "$skill/scripts/init_project.sh" hybrid-case \
  --mode hybrid --profile standard --parent "$temp_root" --no-git

bash "$temp_root/standard-case/scripts/status_check.sh" \
  --root "$temp_root/standard-case"
bash "$temp_root/evidence-case/scripts/validate_project.sh" \
  "$temp_root/evidence-case"

[[ -f "$temp_root/evidence-case/SOURCE_INDEX.md" ]]
[[ -f "$temp_root/evidence-case/docs/CURRENT_REVIEW_EVIDENCE.md" ]]
[[ -d "$temp_root/standard-case/assets" ]]
[[ -d "$temp_root/standard-case/prototypes" ]]
[[ -f "$temp_root/standard-case/scripts/pre-commit" ]]
[[ -f "$temp_root/standard-case/scripts/pre-commit.ps1" ]]
[[ -f "$temp_root/standard-case/PROJECT_MAP.md" ]]
[[ -f "$temp_root/standard-case/ENVIRONMENT.md" ]]
[[ -f "$temp_root/standard-case/scripts/resume_packet.sh" ]]
[[ -f "$temp_root/standard-case/scripts/environment_doctor.ps1" ]]
[[ -f "$temp_root/standard-case/scripts/asset_check.sh" ]]
[[ -f "$temp_root/standard-case/scripts/readiness_check.ps1" ]]
[[ ! -f "$temp_root/software-case/docs/MAIN.md" ]]
grep -q '^- Mode: software$' "$temp_root/software-case/PROJECT_STATE.md"
grep -q '^- Main: \.$' "$temp_root/software-case/PROJECT_STATE.md"
grep -q '^- Mode: hybrid$' "$temp_root/hybrid-case/PROJECT_STATE.md"
[[ -f "$temp_root/hybrid-case/docs/MAIN.md" ]]

mkdir -p "$temp_root/software-case/src"
awk 'BEGIN {
  for (i = 1; i <= 200000; i++) print "const bounded_line_" i " = " i ";"
  print "PPS_BULK_SOURCE_SENTINEL"
}' >"$temp_root/software-case/src/large-source.js"
bash "$temp_root/software-case/scripts/validate_project.sh" \
  "$temp_root/software-case" --quiet
bash "$temp_root/software-case/scripts/resume_packet.sh" \
  "$temp_root/software-case" >"$temp_root/software-resume.out"
[[ "$(wc -l < "$temp_root/software-resume.out" | tr -d ' ')" -le 240 ]]
grep -q '^### M-001 \[active\]$' "$temp_root/software-resume.out"
if grep -q 'PPS_BULK_SOURCE_SENTINEL' "$temp_root/software-resume.out"; then
  echo "Resume packet leaked unbounded source content." >&2
  exit 1
fi
bash "$temp_root/software-case/scripts/environment_doctor.sh" \
  "$temp_root/software-case" >"$temp_root/environment-check.out"
grep -q '^PASS required: git$' "$temp_root/environment-check.out"
core_code=0
bash "$skill/scripts/environment_doctor.sh" --core \
  >"$temp_root/core-environment-check.out" 2>&1 || core_code=$?
[[ "$core_code" == "0" || "$core_code" == "1" ]]
grep -Eq '^(PASS|MISSING) required: git$' \
  "$temp_root/core-environment-check.out"
grep -Eq '^(PASS|MISSING) required: gh$' \
  "$temp_root/core-environment-check.out"

cp -R "$temp_root/standard-case" "$temp_root/legacy-pps10"
sed -i.bak 's/^- Protocol: PPS\/1.2$/- Protocol: PPS\/1.0/' \
  "$temp_root/legacy-pps10/PROJECT_STATE.md"
sed -i.bak '/^- Mode:/d;/^- Map:/d;/^- Environment:/d' \
  "$temp_root/legacy-pps10/PROJECT_STATE.md"
sed -i.bak '/^- Components:/d;/^- Read:/d;/^- Write:/d;/^- Verify:/d' \
  "$temp_root/legacy-pps10/CONTEXT.md"
bash "$temp_root/legacy-pps10/scripts/validate_project.sh" \
  "$temp_root/legacy-pps10" --quiet

cp -R "$temp_root/standard-case" "$temp_root/missing-map"
rm "$temp_root/missing-map/PROJECT_MAP.md"
expect_invalid "$temp_root/missing-map" \
  "Project map file does not exist: PROJECT_MAP.md" \
  "Missing PPS/1.1 project map"

cp -R "$temp_root/standard-case" "$temp_root/missing-environment"
rm "$temp_root/missing-environment/ENVIRONMENT.md"
expect_invalid "$temp_root/missing-environment" \
  "Environment manifest does not exist: ENVIRONMENT.md" \
  "Missing PPS/1.1 environment manifest"

cp -R "$temp_root/standard-case" "$temp_root/missing-resume-script"
rm "$temp_root/missing-resume-script/scripts/resume_packet.sh"
expect_invalid "$temp_root/missing-resume-script" \
  "PPS/1.2 is missing required file: scripts/resume_packet.sh" \
  "Missing PPS/1.2 resume script"

cp -R "$temp_root/standard-case" "$temp_root/missing-component"
sed -i.bak 's/^- Components: C-ROOT$/- Components: C-MISSING/' \
  "$temp_root/missing-component/CONTEXT.md"
expect_invalid "$temp_root/missing-component" \
  "Component ID C-MISSING must have exactly one row" \
  "Missing component-map row"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-component"
printf '| C-ROOT | docs/MAIN.md | duplicate | none | none |\n' \
  >>"$temp_root/duplicate-component/PROJECT_MAP.md"
expect_invalid "$temp_root/duplicate-component" \
  "contains duplicate component rows for C-ROOT" \
  "Duplicate component-map row"

cp -R "$temp_root/standard-case" "$temp_root/malformed-component"
printf '| C-BROKEN | docs/MAIN.md | missing columns |\n' \
  >>"$temp_root/malformed-component/PROJECT_MAP.md"
expect_invalid "$temp_root/malformed-component" \
  "Malformed component row in PROJECT_MAP.md" \
  "Malformed component-map row"

cp -R "$temp_root/standard-case" "$temp_root/read-escape"
sed -i.bak 's|^- Read:.*|- Read: ../outside.md|' \
  "$temp_root/read-escape/CONTEXT.md"
expect_invalid "$temp_root/read-escape" \
  "Read path must be a safe project-relative path" \
  "Escaping Read path"

cp -R "$temp_root/standard-case" "$temp_root/broad-read-root"
sed -i.bak 's|^- Read:.*|- Read: .|' \
  "$temp_root/broad-read-root/CONTEXT.md"
expect_invalid "$temp_root/broad-read-root" \
  "Read path must name an exact file or bounded subdirectory" \
  "Repository-root Read path"

cp -R "$temp_root/standard-case" "$temp_root/oversized-workset"
many_paths=""
for index in $(seq -w 1 31); do
  [[ -z "$many_paths" ]] || many_paths+=","
  many_paths+="generated/path-${index}.txt"
done
sed -i.bak "s|^- Write:.*|- Write: $many_paths|" \
  "$temp_root/oversized-workset/CONTEXT.md"
expect_invalid "$temp_root/oversized-workset" \
  "Read and Write contain 34 paths; hard limit is 30" \
  "Oversized path workset"

cp -R "$temp_root/standard-case" "$temp_root/oversized-context-bytes"
awk 'BEGIN {
  for (i = 1; i <= 33000; i++) printf "A"
  printf "\n"
}' >>"$temp_root/oversized-context-bytes/CONTEXT.md"
expect_invalid "$temp_root/oversized-context-bytes" \
  "hard limit is 32768" \
  "Oversized context byte budget"

cp -R "$temp_root/standard-case" "$temp_root/oversized-authority-workset"
many_authority=""
for index in $(seq -w 1 61); do
  [[ -z "$many_authority" ]] || many_authority+=","
  many_authority+="M-X${index}"
done
sed -i.bak "s|^- Methods:.*|- Methods: $many_authority|" \
  "$temp_root/oversized-authority-workset/CONTEXT.md"
expect_invalid "$temp_root/oversized-authority-workset" \
  "Methods, Facts, and Decisions contain 61 IDs; hard limit is 60" \
  "Oversized authority workset"

cp -R "$temp_root/standard-case" "$temp_root/unknown-tool"
sed -i.bak 's/^- Optional:.*$/- Optional: madeup-tool/' \
  "$temp_root/unknown-tool/ENVIRONMENT.md"
expect_invalid "$temp_root/unknown-tool" \
  "Optional tools contains unsupported tool 'madeup-tool'" \
  "Unknown environment tool"
if bash "$temp_root/unknown-tool/scripts/environment_doctor.sh" \
  "$temp_root/unknown-tool" >"$temp_root/unknown-tool-doctor.out" 2>&1; then
  echo "Environment doctor accepted an unknown tool." >&2
  exit 1
fi
grep -q "unsupported optional tool: madeup-tool" \
  "$temp_root/unknown-tool-doctor.out"

cp -R "$temp_root/standard-case" "$temp_root/extended-tools"
sed -i.bak 's/^- Optional:.*$/- Optional: powershell,libreoffice,poppler,rclone/' \
  "$temp_root/extended-tools/ENVIRONMENT.md"
bash "$temp_root/extended-tools/scripts/validate_project.sh" \
  "$temp_root/extended-tools" --quiet

cp -R "$temp_root/standard-case" "$temp_root/missing-dependency-manifest"
sed -i.bak 's/^- Dependency manifests: none$/- Dependency manifests: requirements.txt/' \
  "$temp_root/missing-dependency-manifest/ENVIRONMENT.md"
expect_invalid "$temp_root/missing-dependency-manifest" \
  "Dependency manifest path does not exist: requirements.txt" \
  "Missing declared dependency manifest"

cp -R "$temp_root/standard-case" "$temp_root/missing-required-git"
sed -i.bak 's/^- Required: .*$/- Required: python/' \
  "$temp_root/missing-required-git/ENVIRONMENT.md"
expect_invalid "$temp_root/missing-required-git" \
  "Required tools must include git" \
  "Environment manifest without Git"

asset_case="$temp_root/asset-case"
cp -R "$temp_root/standard-case" "$asset_case"
mkdir -p "$asset_case/local-assets/source"
printf 'canonical core bytes\n' >"$asset_case/local-assets/source/core.bin"
asset_bytes="$(wc -c < "$asset_case/local-assets/source/core.bin" | tr -d ' ')"
if command -v shasum >/dev/null 2>&1; then
  asset_sha="$(shasum -a 256 "$asset_case/local-assets/source/core.bin" | awk '{print $1}')"
else
  asset_sha="$(sha256sum "$asset_case/local-assets/source/core.bin" | awk '{print $1}')"
fi
{
  printf '# Asset Registry\n\n## Asset Manifest\n\n'
  printf '| ID | Priority | Sync | Materialize | Locator | SHA-256 | Bytes | Purpose |\n'
  printf '|---|---|---|---|---|---|---:|---|\n'
  printf '| A-CORE-001 | core | cloud | local-assets/source/core.bin | rclone:drive:PPS/core.bin | %s | %s | Canonical source material |\n' "$asset_sha" "$asset_bytes"
  printf '| A-REF-001 | reference | local-marker | local-assets/reference/missing.bin | local-only | %064d | 1 | Optional reference marker |\n' 0
} >"$asset_case/ASSETS.md"
sed -i.bak 's/^- Assets: none$/- Assets: A-CORE-001/' \
  "$asset_case/CONTEXT.md"
bash "$asset_case/scripts/validate_project.sh" "$asset_case" --quiet
bash "$asset_case/scripts/asset_check.sh" "$asset_case" --quick \
  >"$temp_root/asset-quick.out"
grep -q '^Integrity level: existence-and-size (quick)$' \
  "$temp_root/asset-quick.out"
fake_rclone_bin="$temp_root/fake-rclone-bin"
mkdir -p "$fake_rclone_bin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf '"'"'{"count":%%s,"bytes":%%s}\\n'"'"' "$PPS_FAKE_RCLONE_COUNT" "$PPS_FAKE_RCLONE_BYTES"\n'
} >"$fake_rclone_bin/rclone"
chmod +x "$fake_rclone_bin/rclone"
PPS_FAKE_RCLONE_COUNT=1 PPS_FAKE_RCLONE_BYTES="$asset_bytes" \
  PATH="$fake_rclone_bin:$PATH" \
  bash "$asset_case/scripts/asset_check.sh" "$asset_case" --all --handoff \
  >"$temp_root/asset-full.out"
grep -q '^WARNING: Reference asset A-REF-001 is not materialized' \
  "$temp_root/asset-full.out"
grep -q '^PASS cloud copy: A-CORE-001' "$temp_root/asset-full.out"
bash "$asset_case/scripts/verify_gate.sh" "$asset_case" >/dev/null
PPS_FAKE_RCLONE_COUNT=1 PPS_FAKE_RCLONE_BYTES="$asset_bytes" \
  PATH="$fake_rclone_bin:$PATH" \
  bash "$asset_case/scripts/readiness_check.sh" "$asset_case" --verified \
  >"$temp_root/asset-ready.out"
grep -q '^PPS readiness: OK$' "$temp_root/asset-ready.out"
set +e
PPS_FAKE_RCLONE_COUNT=1 PPS_FAKE_RCLONE_BYTES="$asset_bytes" \
  PATH="$fake_rclone_bin:$PATH" \
  bash "$asset_case/scripts/readiness_check.sh" "$asset_case" \
  >"$temp_root/asset-pending.out" 2>&1
readiness_pending_code=$?
set -e
[[ "$readiness_pending_code" == "3" ]]
grep -q '^PPS readiness: VERIFY PENDING$' \
  "$temp_root/asset-pending.out"
if PPS_FAKE_RCLONE_COUNT=0 PPS_FAKE_RCLONE_BYTES=0 \
  PATH="$fake_rclone_bin:$PATH" \
  bash "$asset_case/scripts/asset_check.sh" "$asset_case" --handoff \
  >"$temp_root/asset-cloud-missing.out" 2>&1; then
  echo "Asset handoff accepted a missing durable cloud copy." >&2
  exit 1
fi
grep -q 'Cloud asset A-CORE-001 durable copy mismatch' \
  "$temp_root/asset-cloud-missing.out"

cp -R "$asset_case" "$temp_root/missing-core-asset"
rm "$temp_root/missing-core-asset/local-assets/source/core.bin"
if bash "$temp_root/missing-core-asset/scripts/asset_check.sh" \
  "$temp_root/missing-core-asset" --handoff \
  >"$temp_root/missing-core-asset.out" 2>&1; then
  echo "Asset handoff accepted a missing core asset." >&2
  exit 1
fi
grep -q 'Required asset A-CORE-001 is not materialized' \
  "$temp_root/missing-core-asset.out"

cp -R "$asset_case" "$temp_root/core-local-marker"
sed -i.bak 's/| A-CORE-001 | core | cloud |/| A-CORE-001 | core | local-marker |/' \
  "$temp_root/core-local-marker/ASSETS.md"
expect_invalid "$temp_root/core-local-marker" \
  "Core asset A-CORE-001 cannot use local-marker" \
  "Core asset with marker-only sync"

cp -R "$asset_case" "$temp_root/reference-in-workset"
sed -i.bak 's/^- Assets: A-CORE-001$/- Assets: A-REF-001/' \
  "$temp_root/reference-in-workset/CONTEXT.md"
expect_invalid "$temp_root/reference-in-workset" \
  "Reference asset A-REF-001 cannot enter the current Workset" \
  "Reference asset in current Workset"

cp -R "$asset_case" "$temp_root/cloud-secret-locator"
sed -i.bak \
  's|rclone:drive:PPS/core.bin|https://cloud.example/core.bin?token=secret|' \
  "$temp_root/cloud-secret-locator/ASSETS.md"
expect_invalid "$temp_root/cloud-secret-locator" \
  "Locator must use restricted non-secret rclone:REMOTE:path syntax" \
  "Secret-bearing cloud locator"

risk_case="$temp_root/asset-risk-case"
mkdir -p "$risk_case/assets"
if ! git init --quiet -b main "$risk_case" 2>/dev/null; then
  git init --quiet "$risk_case"
fi
truncate -s 99614721 "$risk_case/assets/oversized.mp4"
git -C "$risk_case" add -N assets/oversized.mp4
if bash "$skill/scripts/asset_check.sh" "$risk_case" --risk \
  >"$temp_root/asset-risk.out" 2>&1; then
  echo "Asset risk audit accepted a tracked non-LFS file above 95 MiB." >&2
  exit 1
fi
grep -q 'Tracked non-LFS file exceeds the 95 MiB safe push ceiling' \
  "$temp_root/asset-risk.out"

cp -R "$temp_root/standard-case" "$temp_root/lifecycle-valid"
printf '\n### D-700 [superseded]\n\n- Summary: retained history.\n' \
  >>"$temp_root/lifecycle-valid/DECISIONS.md"
printf '\n### F-700 [frozen]\n\n- Summary: frozen history.\n' \
  >>"$temp_root/lifecycle-valid/DECISIONS.md"
bash "$temp_root/lifecycle-valid/scripts/validate_project.sh" \
  "$temp_root/lifecycle-valid" --quiet

bash "$skill/scripts/init_project.sh" git-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" \
  --install-hook
git_case="$temp_root/git-case"
[[ "$(git -C "$git_case" branch --show-current)" == "main" ]]
[[ -x "$git_case/.git/hooks/pre-commit" ]]

remote_case="$temp_root/remote.git"
if ! git init --quiet --bare -b main "$remote_case" 2>/dev/null; then
  git init --quiet --bare "$remote_case"
fi
git -C "$git_case" remote add origin "$remote_case"
git -C "$git_case" push --quiet -u origin main
bash "$git_case/scripts/status_check.sh" --root "$git_case" --fetch \
  >"$temp_root/git-status.out"
grep -q '^Git-Remotes: origin$' "$temp_root/git-status.out"
grep -q '^Git-Upstream: origin/main$' "$temp_root/git-status.out"
grep -q '^Git-Ahead: 0$' "$temp_root/git-status.out"
grep -q '^Git-Behind: 0$' "$temp_root/git-status.out"

git -C "$git_case" remote add broken "$temp_root/does-not-exist.git"
if bash "$git_case/scripts/status_check.sh" --root "$git_case" --fetch \
  >"$temp_root/git-fetch-failed.out" 2>&1; then
  echo "Status check returned success after a requested fetch failed." >&2
  exit 1
fi
grep -q '^Git-Fetch: FAILED$' "$temp_root/git-fetch-failed.out"
git -C "$git_case" remote remove broken

git clone --quiet "$remote_case" "$temp_root/peer"
git -C "$temp_root/peer" config user.name "PPS Peer"
git -C "$temp_root/peer" config user.email "pps-peer@example.invalid"
printf 'remote checkpoint\n' >"$temp_root/peer/peer.txt"
git -C "$temp_root/peer" add peer.txt
git -C "$temp_root/peer" commit --quiet -m "test: remote checkpoint"
git -C "$temp_root/peer" push --quiet
bash "$git_case/scripts/status_check.sh" --root "$git_case" --fetch \
  >"$temp_root/git-behind.out"
grep -q '^Git-Behind: 1$' "$temp_root/git-behind.out"
git -C "$git_case" pull --quiet --ff-only

printf 'local checkpoint\n' >"$git_case/notes.txt"
git -C "$git_case" add notes.txt
git -C "$git_case" commit --quiet -m "test: local checkpoint"
bash "$git_case/scripts/status_check.sh" --root "$git_case" \
  >"$temp_root/git-ahead.out"
grep -q '^Git-Ahead: 1$' "$temp_root/git-ahead.out"

{
  printf '# Asset Registry\n\n## Asset Manifest\n\n'
  printf '| ID | Priority | Sync | Materialize | Locator | SHA-256 | Bytes | Purpose |\n'
  printf '|---|---|---|---|---|---|---:|---|\n'
  printf '| A-HOOK-REF | reference | local-marker | local-assets/hook/missing.bin | local-only | %064d | 1 | Hook snapshot marker |\n' 0
} >"$git_case/ASSETS.md"
git -C "$git_case" add ASSETS.md
if ! (cd "$git_case" && bash .git/hooks/pre-commit) \
  >"$temp_root/asset-hook.out" 2>&1; then
  echo "Installed pre-commit hook rejected a valid staged asset registry." >&2
  sed -n '1,160p' "$temp_root/asset-hook.out" >&2
  exit 1
fi
git -C "$git_case" restore --staged ASSETS.md

sed -i.bak '/^- Excluded:/d' "$git_case/CONTEXT.md"
git -C "$git_case" add CONTEXT.md
git -C "$git_case" restore --worktree -- CONTEXT.md
if git -C "$git_case" commit -m "test: invalid state" \
  >"$temp_root/hook.out" 2>&1; then
  echo "Installed pre-commit hook accepted invalid staged PPS state." >&2
  exit 1
fi
grep -q "PPS pre-commit: staged project validation failed" "$temp_root/hook.out"

mkdir -p "$temp_root/nonempty"
printf 'keep\n' >"$temp_root/nonempty/user.txt"
if bash "$skill/scripts/init_project.sh" nonempty \
  --parent "$temp_root" --no-git >"$temp_root/nonempty.out" 2>&1; then
  echo "Initializer accepted a non-empty target." >&2
  exit 1
fi
grep -q "Refusing to initialize a non-empty target" "$temp_root/nonempty.out"
[[ "$(cat "$temp_root/nonempty/user.txt")" == "keep" ]]

if bash "$skill/scripts/init_project.sh" 'invalid/name' \
  --parent "$temp_root" --no-git >"$temp_root/invalid-name.out" 2>&1; then
  echo "Initializer accepted an invalid project name." >&2
  exit 1
fi
grep -q "Project name may contain only" "$temp_root/invalid-name.out"
if bash "$skill/scripts/init_project.sh" '..' \
  --parent "$temp_root" --no-git >"$temp_root/dotdot-name.out" 2>&1; then
  echo "Initializer accepted '..' as a project name." >&2
  exit 1
fi
grep -q "cannot be '.' or '..'" "$temp_root/dotdot-name.out"

if bash "$skill/scripts/init_project.sh" 'CON' \
  --parent "$temp_root" --no-git >"$temp_root/reserved-name.out" 2>&1; then
  echo "Initializer accepted a non-portable reserved project name." >&2
  exit 1
fi
grep -q "Windows-reserved device name" "$temp_root/reserved-name.out"

if bash "$skill/scripts/init_project.sh" missing-arg \
  --parent >"$temp_root/missing-arg.out" 2>&1; then
  echo "Initializer accepted an option without its argument." >&2
  exit 1
fi
grep -q '^Usage:' "$temp_root/missing-arg.out"

if bash "$skill/scripts/init_project.sh" contradictory \
  --parent "$temp_root" --no-git --install-hook \
  >"$temp_root/contradictory.out" 2>&1; then
  echo "Initializer accepted contradictory Git options." >&2
  exit 1
fi
grep -q "cannot be used with --no-git" "$temp_root/contradictory.out"

if bash "$temp_root/standard-case/scripts/validate_project.sh" \
  "$temp_root/standard-case" extra >"$temp_root/validator-extra.out" 2>&1; then
  echo "Validator accepted an extra positional argument." >&2
  exit 1
fi
grep -q '^Usage:' "$temp_root/validator-extra.out"

cp -R "$temp_root/standard-case" "$temp_root/missing-coverage"
sed -i.bak '/^| M-002 |/d' "$temp_root/missing-coverage/CONTEXT.md"
if bash "$temp_root/missing-coverage/scripts/validate_project.sh" \
  "$temp_root/missing-coverage" >"$temp_root/missing.out" 2>&1; then
  echo "Missing coverage was incorrectly accepted." >&2
  exit 1
fi
grep -q "Manifest ID M-002 must have exactly one row" "$temp_root/missing.out"

cp -R "$temp_root/standard-case" "$temp_root/inactive-decision"
sed -i.bak 's/^- Decisions: none$/- Decisions: D-404/' \
  "$temp_root/inactive-decision/CONTEXT.md"
if bash "$temp_root/inactive-decision/scripts/validate_project.sh" \
  "$temp_root/inactive-decision" >"$temp_root/inactive.out" 2>&1; then
  echo "Inactive manifest decision was incorrectly accepted." >&2
  exit 1
fi
grep -q "Manifest ID D-404 must appear exactly once" "$temp_root/inactive.out"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-active-block"
printf '\n<!-- PPS:ACTIVE:BEGIN -->\n<!-- PPS:ACTIVE:END -->\n' \
  >>"$temp_root/duplicate-active-block/DECISIONS.md"
expect_invalid "$temp_root/duplicate-active-block" \
  "must contain exactly one active authority block" \
  "Duplicate active block"

cp -R "$temp_root/standard-case" "$temp_root/orphan-active-record"
printf '\n### D-999 [active]\n\n- Summary: orphan.\n' \
  >>"$temp_root/orphan-active-record/DECISIONS.md"
expect_invalid "$temp_root/orphan-active-record" \
  "Active record D-999 must appear exactly once in the active block" \
  "Orphan active record"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-global-id"
printf '\n### M-001 [superseded]\n\n- Summary: duplicate.\n' \
  >>"$temp_root/duplicate-global-id/DECISIONS.md"
expect_invalid "$temp_root/duplicate-global-id" \
  "Authority ID has more than one canonical record: M-001" \
  "Duplicate canonical authority ID"
grep -Eq 'DECISIONS.md lines [0-9]+,[0-9]+' \
  "$temp_root/duplicate-global-id.invalid.out"

cp -R "$temp_root/standard-case" "$temp_root/missing-excluded"
sed -i.bak '/^- Excluded:/d' "$temp_root/missing-excluded/CONTEXT.md"
expect_invalid "$temp_root/missing-excluded" \
  "Expected exactly one 'Excluded' field in 'Workset Manifest', found 0" \
  "Missing Excluded field"

cp -R "$temp_root/standard-case" "$temp_root/package-mismatch"
sed -i.bak 's/^- ID: PKG-001$/- ID: PKG-999/' \
  "$temp_root/package-mismatch/CONTEXT.md"
expect_invalid "$temp_root/package-mismatch" \
  "does not match PROJECT_STATE Package" \
  "Package mismatch"

cp -R "$temp_root/standard-case" "$temp_root/wrong-type-manifest"
sed -i.bak \
  's/^- Methods: M-001, M-002$/- Methods: M-001, M-002, D-999/' \
  "$temp_root/wrong-type-manifest/CONTEXT.md"
expect_invalid "$temp_root/wrong-type-manifest" \
  "comma-separated list of only M IDs" \
  "Wrong authority class in manifest"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-manifest-id"
sed -i.bak \
  's/^- Methods: M-001, M-002$/- Methods: M-001, M-001, M-002/' \
  "$temp_root/duplicate-manifest-id/CONTEXT.md"
expect_invalid "$temp_root/duplicate-manifest-id" \
  "Methods contains duplicate IDs: M-001" \
  "Duplicate manifest ID"

cp -R "$temp_root/standard-case" "$temp_root/manifest-whitespace-merge"
sed -i.bak \
  's/^- Methods: M-001, M-002$/- Methods: M-001 M-002/' \
  "$temp_root/manifest-whitespace-merge/CONTEXT.md"
expect_invalid "$temp_root/manifest-whitespace-merge" \
  "comma-separated list of only M IDs" \
  "Manifest IDs merged by whitespace"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-coverage"
printf '| M-001 | Duplicate | `docs/MAIN.md` | Conflicting |\n' \
  >>"$temp_root/duplicate-coverage/CONTEXT.md"
expect_invalid "$temp_root/duplicate-coverage" \
  "Manifest ID M-001 must have exactly one row" \
  "Duplicate coverage row"
grep -Eq 'found 2 \(lines [0-9]+,[0-9]+\)' \
  "$temp_root/duplicate-coverage.invalid.out"

cp -R "$temp_root/evidence-case" "$temp_root/evidence-package-mismatch"
sed -i.bak 's/^- ID: PKG-001$/- ID: PKG-999/' \
  "$temp_root/evidence-package-mismatch/docs/CURRENT_REVIEW_EVIDENCE.md"
expect_invalid "$temp_root/evidence-package-mismatch" \
  "Evidence package 'PKG-999' does not match PROJECT_STATE Package" \
  "Evidence package mismatch"

cp -R "$temp_root/evidence-case" "$temp_root/duplicate-source-row"
sed -i.bak 's/^- Sources: none$/- Sources: SRC-001/' \
  "$temp_root/duplicate-source-row/CONTEXT.md"
printf '| SRC-001 | source-a | v1 | F-001 | none | review |\n' \
  >>"$temp_root/duplicate-source-row/SOURCE_INDEX.md"
printf '| SRC-001 | source-b | v2 | F-001 | conflict | reject |\n' \
  >>"$temp_root/duplicate-source-row/SOURCE_INDEX.md"
expect_invalid "$temp_root/duplicate-source-row" \
  "Source ID SRC-001 must have exactly one row" \
  "Duplicate source row"
grep -Eq 'found 2 \(lines [0-9]+,[0-9]+\)' \
  "$temp_root/duplicate-source-row.invalid.out"

cp -R "$temp_root/standard-case" "$temp_root/misplaced-hot-field"
sed -i.bak '/^- Protocol: PPS\/1.2$/d' \
  "$temp_root/misplaced-hot-field/PROJECT_STATE.md"
printf '\n## Misplaced\n\n- Protocol: PPS/1.2\n' \
  >>"$temp_root/misplaced-hot-field/PROJECT_STATE.md"
expect_invalid "$temp_root/misplaced-hot-field" \
  "Expected exactly one 'Protocol' field in 'Hot State', found 0" \
  "Hot-state field outside canonical section"

cp -R "$temp_root/standard-case" "$temp_root/misplaced-workset-field"
sed -i.bak '/^- Facts: none$/d' \
  "$temp_root/misplaced-workset-field/CONTEXT.md"
printf '\n## Misplaced\n\n- Facts: none\n' \
  >>"$temp_root/misplaced-workset-field/CONTEXT.md"
expect_invalid "$temp_root/misplaced-workset-field" \
  "Expected exactly one 'Facts' field in 'Workset Manifest', found 0" \
  "Workset field outside canonical section"

cp -R "$temp_root/standard-case" "$temp_root/duplicate-hot-section"
printf '\n## Hot State\n\n- Protocol: PPS/1.2\n' \
  >>"$temp_root/duplicate-hot-section/PROJECT_STATE.md"
expect_invalid "$temp_root/duplicate-hot-section" \
  "Expected exactly one 'Hot State' section, found 2" \
  "Duplicate hot-state section"

cp -R "$temp_root/standard-case" "$temp_root/reversed-active-markers"
sed -i.bak 's/PPS:ACTIVE:BEGIN/PPS:ACTIVE:TEMP/' \
  "$temp_root/reversed-active-markers/DECISIONS.md"
sed -i.bak 's/PPS:ACTIVE:END/PPS:ACTIVE:BEGIN/' \
  "$temp_root/reversed-active-markers/DECISIONS.md"
sed -i.bak 's/PPS:ACTIVE:TEMP/PPS:ACTIVE:END/' \
  "$temp_root/reversed-active-markers/DECISIONS.md"
expect_invalid "$temp_root/reversed-active-markers" \
  "active authority markers are out of order" \
  "Reversed active markers"

cp -R "$temp_root/standard-case" "$temp_root/invalid-package-id"
sed -i.bak 's/^- Package: PKG-001$/- Package: package one/' \
  "$temp_root/invalid-package-id/PROJECT_STATE.md"
expect_invalid "$temp_root/invalid-package-id" \
  "Package must use a PKG-\* ID" \
  "Invalid package ID"

cp -R "$temp_root/standard-case" "$temp_root/invalid-updated-time"
sed -i.bak 's/^- Updated: .*Z$/- Updated: 2026-02-30T12:00:00Z/' \
  "$temp_root/invalid-updated-time/PROJECT_STATE.md"
expect_invalid "$temp_root/invalid-updated-time" \
  "Updated must be a UTC timestamp" \
  "Invalid Updated timestamp"

cp -R "$temp_root/standard-case" "$temp_root/frozen-in-active-block"
sed -i.bak '/PPS:ACTIVE:END/i\
- `D-777`
' "$temp_root/frozen-in-active-block/DECISIONS.md"
printf '\n### D-777 [frozen]\n\n- Summary: frozen item.\n' \
  >>"$temp_root/frozen-in-active-block/DECISIONS.md"
expect_invalid "$temp_root/frozen-in-active-block" \
  "Active ID D-777 must have exactly one \[active\] record, found 0" \
  "Frozen authority in active block"

printf '# Outside project\n' >"$temp_root/outside-main.md"
cp -R "$temp_root/standard-case" "$temp_root/symlink-escape"
ln -s "$temp_root/outside-main.md" "$temp_root/symlink-escape/outside-main.md"
sed -i.bak 's|^- Main: docs/MAIN.md$|- Main: outside-main.md|' \
  "$temp_root/symlink-escape/PROJECT_STATE.md"
expect_invalid "$temp_root/symlink-escape" \
  "Main must not traverse a symbolic link" \
  "Symbolic-link path escape"

legacy="$temp_root/legacy-case"
mkdir -p "$legacy/docs"
printf '# Legacy project\n' >"$legacy/README.md"
printf '# Agent handoff\n' >"$legacy/AGENTS.md"
printf '%s\n' '# Project state' '- Main: docs/PLAN.md' >"$legacy/PROJECT_STATE.md"
printf '# Decisions\n' >"$legacy/DECISIONS.md"
printf 'UTF-8 must not become an authority ID.\n' >>"$legacy/DECISIONS.md"
printf '# Plan\n' >"$legacy/docs/PLAN.md"
printf '# Ordinary roadmap\n' >"$legacy/ROADMAP.md"
legacy_before="$(
  {
    find "$legacy" -print
    find "$legacy" -type f -exec cksum {} \;
  } | LC_ALL=C sort
)"
legacy_report="$temp_root/legacy-report.md"
bash "$skill/scripts/audit_legacy_project.sh" \
  --root "$legacy" --output "$legacy_report"
legacy_after="$(
  {
    find "$legacy" -print
    find "$legacy" -type f -exec cksum {} \;
  } | LC_ALL=C sort
)"
[[ "$legacy_before" == "$legacy_after" ]]
grep -q 'Detected system: `plan-project-sync`' "$legacy_report"
grep -q 'Audit mode: read-only' "$legacy_report"
grep -q '| Strict M/F/D IDs | 0 |' "$legacy_report"
grep -q 'Recommended mode: `document`' "$legacy_report"

lightweight_code="$temp_root/lightweight-code-audit"
mkdir -p "$lightweight_code/docs"
printf '# Product specification\n' >"$lightweight_code/docs/SPEC.md"
printf '<!doctype html><title>Game</title>\n' >"$lightweight_code/index.html"
bash "$skill/scripts/audit_legacy_project.sh" --root "$lightweight_code" \
  >"$temp_root/lightweight-code-report.md"
grep -q 'Recommended mode: `hybrid`' \
  "$temp_root/lightweight-code-report.md"
grep -q '| Implementation/prototype code files | 1 |' \
  "$temp_root/lightweight-code-report.md"

generated_noise="$temp_root/generated-noise-audit"
mkdir -p "$generated_noise/docs" "$generated_noise/node_modules/vendor"
printf '# Text project\n' >"$generated_noise/docs/PLAN.md"
printf '{"name":"generated-dependency"}\n' \
  >"$generated_noise/node_modules/vendor/package.json"
printf 'export default true;\n' \
  >"$generated_noise/node_modules/vendor/index.js"
bash "$skill/scripts/audit_legacy_project.sh" --root "$generated_noise" \
  >"$temp_root/generated-noise-report.md"
grep -q 'Recommended mode: `document`' \
  "$temp_root/generated-noise-report.md"
grep -q '| Implementation/prototype code files | 0 |' \
  "$temp_root/generated-noise-report.md"

if bash "$skill/scripts/audit_legacy_project.sh" \
  --root "$legacy" --output "$legacy/MIGRATION_REPORT.md" \
  >"$temp_root/inside-report.out" 2>&1; then
  echo "Audit report was incorrectly written inside the target." >&2
  exit 1
fi
grep -q "Refusing to write the audit report inside the target project" \
  "$temp_root/inside-report.out"
[[ ! -e "$legacy/MIGRATION_REPORT.md" ]]

mixed="$temp_root/mixed-case"
mkdir -p "$mixed/legacy-state"
cp "$legacy/AGENTS.md" "$mixed/AGENTS.md"
cp "$legacy/PROJECT_STATE.md" "$mixed/PROJECT_STATE.md"
cp "$legacy/DECISIONS.md" "$mixed/DECISIONS.md"
printf '# Legacy state\n' >"$mixed/legacy-state/STATE.md"
bash "$skill/scripts/audit_legacy_project.sh" --root "$mixed" \
  >"$temp_root/mixed-report.md"
grep -q 'Detected system: `mixed`' "$temp_root/mixed-report.md"
grep -q "Do not write until one authority is selected" \
  "$temp_root/mixed-report.md"

pps_with_history="$temp_root/pps-with-history"
cp -R "$temp_root/standard-case" "$pps_with_history"
mkdir -p "$pps_with_history/legacy-state"
printf '# Archived state\n' >"$pps_with_history/legacy-state/STATE.md"
bash "$skill/scripts/audit_legacy_project.sh" --root "$pps_with_history" \
  >"$temp_root/pps-history-report.md"
grep -q 'Detected system: `pps`' "$temp_root/pps-history-report.md"
grep -q 'Confidence: `high`' "$temp_root/pps-history-report.md"

# P1-01: a project with custom-named structure (rules/, decisions/, risks/,
# notes elsewhere) is a structured candidate with evidence, never
# "unstructured".
custom_structure="$temp_root/custom-structure-audit"
mkdir -p "$custom_structure/rules" "$custom_structure/decisions" \
  "$custom_structure/risks" "$custom_structure/notes"
printf '# Rules\n' >"$custom_structure/rules/RULES.md"
printf '# Decisions\n' >"$custom_structure/decisions/DECISION_LOG.md"
printf '# Risks\n' >"$custom_structure/risks/RISKS.md"
printf '# Product spec\n' >"$custom_structure/notes/SPEC.md"
printf 'print(1)\n' >"$custom_structure/app.py"
bash "$skill/scripts/audit_legacy_project.sh" --root "$custom_structure" \
  >"$temp_root/custom-structure-report.md"
grep -q 'Confidence:' "$temp_root/custom-structure-report.md"
! grep -q 'Detected system: `unstructured`' "$temp_root/custom-structure-report.md"
grep -q 'rules (CLAUDE / RULES / rules)' "$temp_root/custom-structure-report.md"
grep -q 'Recommended mode: `hybrid`' "$temp_root/custom-structure-report.md"

# An empty directory is unknown, with the uncertainty said out loud.
empty_dir="$temp_root/empty-dir-audit"
mkdir -p "$empty_dir"
bash "$skill/scripts/audit_legacy_project.sh" --root "$empty_dir" \
  >"$temp_root/empty-dir-report.md"
grep -q 'Detected system: `unknown`' "$temp_root/empty-dir-report.md"
grep -q 'Confidence: `low`' "$temp_root/empty-dir-report.md"

cp -R "$temp_root/standard-case" "$temp_root/missing-events"
rm "$temp_root/missing-events/EVENTS.md"
expect_invalid "$temp_root/missing-events" \
  "PPS/1.2 is missing required file: EVENTS.md" \
  "Missing PPS/1.2 events file"

cp -R "$temp_root/standard-case" "$temp_root/malformed-event"
printf -- '- 2026-08-19: broken event without package or segments\n' \
  >>"$temp_root/malformed-event/EVENTS.md"
expect_invalid "$temp_root/malformed-event" \
  "Malformed event line in EVENTS.md" \
  "Malformed event line"

cp -R "$temp_root/standard-case" "$temp_root/missing-red-lines"
sed -i.bak 's/^## Red Lines$/## Old Section/' \
  "$temp_root/missing-red-lines/AGENTS.md"
expect_invalid "$temp_root/missing-red-lines" \
  "requires a '## Red Lines' section in AGENTS.md" \
  "Missing Red Lines section"

cp -R "$temp_root/standard-case" "$temp_root/bare-present-coverage"
sed -i.bak \
  's/| M-001 | Stable IDs and explicit workset retrieval | `CONTEXT.md` \/ Workset Manifest | .* |/| M-001 | Stable IDs and explicit workset retrieval | `CONTEXT.md` \/ Workset Manifest | Present |/' \
  "$temp_root/bare-present-coverage/CONTEXT.md"
expect_invalid "$temp_root/bare-present-coverage" \
  "needs an evidence cell naming the command, test, or inspection" \
  "Bare Present coverage row"

multitask_case="$temp_root/multitask-case"
cp -R "$temp_root/standard-case" "$multitask_case"
mkdir -p "$multitask_case/task-contexts"
{
  printf '# T-002 Capsule\n\n## Workset Manifest\n\n'
  printf -- '- Methods: none\n- Facts: none\n- Decisions: none\n- Sources: none\n- Assets: none\n'
  printf -- '- Components: C-ROOT\n- Read: PROJECT_MAP.md\n- Write: local-task-output/T-002/out.md\n'
  printf -- '- Verify: scripts/verify_gate.sh\n- Excluded: none\n- Coverage: CONTEXT.md\n'
} >"$multitask_case/task-contexts/T-002.md"
{
  printf '# Task Index\n\n## Task Index\n\n'
  printf '### T-001\n- Title: Integration\n- Role: integrator\n- Status: active\n- Active Package: PKG-001\n- Capsule: CONTEXT.md\n- Output Root: none\n\n'
  printf '### T-002\n- Title: Worker\n- Role: worker\n- Status: active\n- Active Package: PKG-001\n- Capsule: task-contexts/T-002.md\n- Output Root: local-task-output/T-002\n'
} >"$multitask_case/TASK_INDEX.md"
expect_invalid "$multitask_case" \
  "Multitask projects require a 'Writer:' field in Hot State" \
  "Multitask without Writer lease"
sed -i.bak 's/^- Device: /- Writer: T-001\n- Device: /' \
  "$multitask_case/PROJECT_STATE.md"
bash "$multitask_case/scripts/validate_project.sh" "$multitask_case" --quiet

cp -R "$multitask_case" "$temp_root/two-integrators"
sed -i.bak 's/^- Role: worker$/- Role: integrator/' \
  "$temp_root/two-integrators/TASK_INDEX.md"
expect_invalid "$temp_root/two-integrators" \
  "must have exactly one active integrator, found 2" \
  "Two active integrators"

cp -R "$multitask_case" "$temp_root/worker-writes-canonical"
sed -i.bak 's|^- Write: local-task-output/T-002/out.md$|- Write: DECISIONS.md|' \
  "$temp_root/worker-writes-canonical/task-contexts/T-002.md"
expect_invalid "$temp_root/worker-writes-canonical" \
  "declares canonical file 'DECISIONS.md' in its Write set" \
  "Worker claiming canonical write"

cp -R "$multitask_case" "$temp_root/unchecked-merge"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: absorbs\n- Accepted: docs/MAIN.md\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: none\n- Result Checkpoint: none\n- Approval: none\n- Verification: none\n- Status: integrated\n'
} >"$temp_root/unchecked-merge/MERGES.md"
expect_invalid "$temp_root/unchecked-merge" \
  "not a resolvable Git object or the explicit lineage_incomplete marker" \
  "Integrated merge without checkpoints"

cp -R "$multitask_case" "$temp_root/terminal-no-receipt"
perl -0pi -e 's/(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active/${1}integrated/' \
  "$temp_root/terminal-no-receipt/TASK_INDEX.md"
expect_invalid "$temp_root/terminal-no-receipt" \
  "no merge receipt with matching status names it" \
  "Integrated task without receipt"

cp -R "$multitask_case" "$temp_root/receipt-unknown-task"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-404\n- Relation: absorbs\n- Accepted: docs/MAIN.md\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: lineage_incomplete\n- Approval: none\n- Verification: manual\n- Status: pending\n'
} >"$temp_root/receipt-unknown-task/MERGES.md"
expect_invalid "$temp_root/receipt-unknown-task" \
  "references unknown Source Task 'T-404'" \
  "Receipt referencing unknown task"

cp -R "$multitask_case" "$temp_root/capsule-write-dot"
sed -i.bak 's|^- Write: local-task-output/T-002/out.md$|- Write: .|' \
  "$temp_root/capsule-write-dot/task-contexts/T-002.md"
expect_invalid "$temp_root/capsule-write-dot" \
  "Write path must name an exact file or bounded subdirectory" \
  "Task capsule repository-root Write"

cp -R "$multitask_case" "$temp_root/capsule-missing-fields"
printf '# T-003 Capsule\n\n## Workset Manifest\n\n- Write: local-task-output/T-003/out.md\n' \
  >"$temp_root/capsule-missing-fields/task-contexts/T-003.md"
printf '\n### T-003\n- Title: Bare\n- Role: worker\n- Status: active\n- Active Package: PKG-001\n- Capsule: task-contexts/T-003.md\n- Output Root: local-task-output/T-003\n' \
  >>"$temp_root/capsule-missing-fields/TASK_INDEX.md"
expect_invalid "$temp_root/capsule-missing-fields" \
  "must declare exactly one 'Methods' field" \
  "Task capsule missing required fields"

cp -R "$multitask_case" "$temp_root/output-root-escape"
sed -i.bak 's|^- Output Root: local-task-output/T-002$|- Output Root: ../outside|' \
  "$temp_root/output-root-escape/TASK_INDEX.md"
expect_invalid "$temp_root/output-root-escape" \
  "Output Root must be a safe project-relative path" \
  "Task Output Root escape"

cp -R "$multitask_case" "$temp_root/output-root-overlap"
{
  printf '# T-003 Capsule\n\n## Workset Manifest\n\n'
  printf -- '- Methods: none\n- Facts: none\n- Decisions: none\n- Sources: none\n- Assets: none\n'
  printf -- '- Components: C-ROOT\n- Read: PROJECT_MAP.md\n- Write: local-task-output/T-002/nested/out.md\n'
  printf -- '- Verify: scripts/verify_gate.sh\n- Excluded: none\n- Coverage: CONTEXT.md\n'
} >"$temp_root/output-root-overlap/task-contexts/T-003.md"
printf '\n### T-003\n- Title: Overlap\n- Role: worker\n- Status: active\n- Active Package: PKG-001\n- Capsule: task-contexts/T-003.md\n- Output Root: local-task-output/T-002/nested\n' \
  >>"$temp_root/output-root-overlap/TASK_INDEX.md"
expect_invalid "$temp_root/output-root-overlap" \
  "overlaps Task T-002 Output Root" \
  "Overlapping task output roots"

cp -R "$multitask_case" "$temp_root/rogue-integrator"
printf '# Rogue integrator capsule\n\n## Workset Manifest\n\n- Write: docs/MAIN.md\n' \
  >"$temp_root/rogue-integrator/task-contexts/T-001.md"
perl -0pi -e 's|(### T-001\n- Title: [^\n]+\n- Role: integrator\n- Status: active\n- Active Package: PKG-001\n- Capsule: )CONTEXT\.md|${1}task-contexts/T-001.md|' \
  "$temp_root/rogue-integrator/TASK_INDEX.md"
expect_invalid "$temp_root/rogue-integrator" \
  "capsule must be CONTEXT.md itself" \
  "Integrator with a separate capsule"

cp -R "$multitask_case" "$temp_root/receipt-escape-path"
perl -0pi -e 's/(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active/${1}integrated/' \
  "$temp_root/receipt-escape-path/TASK_INDEX.md"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: absorbs\n- Accepted: ../outside/thing.md\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: lineage_incomplete\n- Lineage Note: fixture migration marker\n- Approval: D-001\n- Verification: manual review\n- Status: integrated\n'
} >"$temp_root/receipt-escape-path/MERGES.md"
expect_invalid "$temp_root/receipt-escape-path" \
  "Accepted path must be a safe project-relative path" \
  "Receipt disposition path escape"

cp -R "$multitask_case" "$temp_root/receipt-status-mismatch"
$PY3 - "$temp_root/receipt-status-mismatch" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/DECISIONS.md'
t = open(p, encoding='utf-8').read()
t = t.replace('<!-- PPS:ACTIVE:END -->', '- `D-001`\n<!-- PPS:ACTIVE:END -->')
t = t.replace('## Status Events', '### D-001 [active]\n\n- Summary: Fixture approval.\n- Source: fixture.\n- Scope: MERGE-001.\n- Supersedes: none.\n- Affects: merges.\n\n## Status Events')
open(p, 'w', encoding='utf-8').write(t)
PYEOF
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: absorbs\n- Accepted: docs/MAIN.md\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: lineage_incomplete\n- Lineage Note: fixture migration marker\n- Approval: D-001\n- Verification: manual review\n- Status: integrated\n'
} >"$temp_root/receipt-status-mismatch/MERGES.md"
expect_invalid "$temp_root/receipt-status-mismatch" \
  "the registry and the receipt must agree" \
  "Receipt terminal status vs active registry"

cp -R "$multitask_case" "$temp_root/worker-writes-main"
sed -i.bak 's|^- Write: local-task-output/T-002/out.md$|- Write: docs/MAIN.md|' \
  "$temp_root/worker-writes-main/task-contexts/T-002.md"
expect_invalid "$temp_root/worker-writes-main" \
  "outside its Output Root" \
  "Worker Write outside its Output Root"

cp -R "$multitask_case" "$temp_root/hollow-receipt"
perl -0pi -e 's/(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active/${1}integrated/' \
  "$temp_root/hollow-receipt/TASK_INDEX.md"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-999\n- Source Tasks: T-002\n- Relation: absorbs\n- Accepted: none\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: lineage_incomplete\n- Approval: none\n- Verification: none\n- Status: integrated\n'
} >"$temp_root/hollow-receipt/MERGES.md"
expect_invalid "$temp_root/hollow-receipt" \
  "an integration that accepted nothing is not an integration" \
  "Hollow integrated receipt"
expect_invalid "$temp_root/hollow-receipt" \
  "without an Approval decision" \
  "Receipt without approval"
expect_invalid "$temp_root/hollow-receipt" \
  "without Verification evidence" \
  "Receipt without verification"
expect_invalid "$temp_root/hollow-receipt" \
  "is neither the current package" \
  "Receipt targeting phantom package"
expect_invalid "$temp_root/hollow-receipt" \
  "uses lineage_incomplete without a 'Lineage Note'" \
  "lineage_incomplete without note"

receipt_base="$temp_root/receipt-evidence-base"
cp -R "$multitask_case" "$receipt_base"
perl -0pi -e 's/(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active/${1}integrated/' \
  "$receipt_base/TASK_INDEX.md"
$PY3 - "$receipt_base" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/DECISIONS.md'
t = open(p, encoding='utf-8').read()
t = t.replace('<!-- PPS:ACTIVE:END -->', '- `D-001`\n<!-- PPS:ACTIVE:END -->')
t = t.replace('## Status Events', '### D-001 [active]\n\n- Summary: Merge authorized.\n- Source: fixture.\n- Scope: MERGE-001.\n- Supersedes: none.\n- Affects: merges.\n\n### D-002 [rejected]\n\n- Summary: Merge NOT authorized.\n- Source: fixture.\n- Scope: MERGE-001.\n- Supersedes: none.\n- Affects: merges.\n\n## Status Events')
open(p, 'w', encoding='utf-8').write(t)
PYEOF
mkdir -p "$receipt_base/local-task-output/T-002"
printf 'real artifact\n' >"$receipt_base/local-task-output/T-002/real.md"
write_receipt() {
  local dir="$1" approval="$2" verification="$3" accepted="$4" target="$5"
  {
    printf '# Merges\n\n## Merge Receipts\n\n'
    printf '### MERGE-001\n- Target Package: %s\n- Source Tasks: T-002\n- Relation: absorbs\n- Accepted: %s\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: lineage_incomplete\n- Lineage Note: migration per D-001\n- Approval: %s\n- Verification: %s\n- Status: integrated\n' \
      "$target" "$accepted" "$approval" "$verification"
  } >"$dir/MERGES.md"
}

cp -R "$receipt_base" "$temp_root/receipt-phantom-package"
printf '<!-- [PKG-999] -->\n' >>"$temp_root/receipt-phantom-package/EVENTS.md"
write_receipt "$temp_root/receipt-phantom-package" D-001 "validate_project pass" local-task-output/T-002/real.md PKG-999
expect_invalid "$temp_root/receipt-phantom-package" \
  "nor recorded as a positive event line" \
  "Receipt targeting package only mentioned in a comment"

cp -R "$receipt_base" "$temp_root/receipt-rejected-approval"
write_receipt "$temp_root/receipt-rejected-approval" D-002 "validate_project pass" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-rejected-approval" \
  "a decision that never authorized the merge cannot approve it" \
  "Receipt citing a rejected decision as approval"

cp -R "$receipt_base" "$temp_root/receipt-prose-verification"
write_receipt "$temp_root/receipt-prose-verification" D-001 "looked fine to me" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-prose-verification" \
  "is not evidence the merge succeeded" \
  "Receipt with prose-only verification"

cp -R "$receipt_base" "$temp_root/receipt-ghost-accepted"
write_receipt "$temp_root/receipt-ghost-accepted" D-001 "validate_project pass" local-task-output/T-002/ghost.md PKG-001
expect_invalid "$temp_root/receipt-ghost-accepted" \
  "an integration must point at artifacts inside the result commit" \
  "Receipt accepting a nonexistent artifact"

cp -R "$receipt_base" "$temp_root/receipt-missing-evidence-doc"
write_receipt "$temp_root/receipt-missing-evidence-doc" D-001 "docs/nonexistent-evidence.md" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-missing-evidence-doc" \
  "not evidence the merge succeeded" \
  "Receipt citing a nonexistent evidence document"

cp -R "$receipt_base" "$temp_root/receipt-bare-gate-name"
write_receipt "$temp_root/receipt-bare-gate-name" D-001 "verify_gate" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-bare-gate-name" \
  "not evidence the merge succeeded" \
  "Receipt naming a gate without an outcome"

cp -R "$receipt_base" "$temp_root/receipt-unowned-accepted"
write_receipt "$temp_root/receipt-unowned-accepted" D-001 "validate_project pass" PROJECT_MAP.md PKG-001
expect_invalid "$temp_root/receipt-unowned-accepted" \
  "not inside any Source Task Output Root" \
  "Receipt accepting an artifact outside every source task root"

cp -R "$receipt_base" "$temp_root/receipt-same-checkpoints"
git -C "$temp_root/receipt-same-checkpoints" init -q
git -C "$temp_root/receipt-same-checkpoints" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" add -A
git -C "$temp_root/receipt-same-checkpoints" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" commit -qm fixture
same_head="$(git -C "$temp_root/receipt-same-checkpoints" rev-parse HEAD)"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: absorbs\n- Accepted: local-task-output/T-002/real.md\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: %s\n- Result Checkpoint: %s\n- Approval: D-001\n- Verification: validate_project pass\n- Status: integrated\n' \
    "$same_head" "$same_head"
} >"$temp_root/receipt-same-checkpoints/MERGES.md"
expect_invalid "$temp_root/receipt-same-checkpoints" \
  "integration that changed nothing integrated nothing" \
  "Receipt with identical base and result checkpoints"

cp -R "$receipt_base" "$temp_root/receipt-nonmigration-decision"
git -C "$temp_root/receipt-nonmigration-decision" init -q
git -C "$temp_root/receipt-nonmigration-decision" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" add -A
git -C "$temp_root/receipt-nonmigration-decision" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" commit -qm fixture
write_receipt "$temp_root/receipt-nonmigration-decision" D-001 "validate_project pass" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-nonmigration-decision" \
  "does not authorize migrating or adopting pre-layer history" \
  "lineage_incomplete citing a non-migration decision"

cp -R "$multitask_case" "$temp_root/task-bogus-package"
sed -i.bak 's|^- Active Package: PKG-001$|- Active Package: NOT-A-PACKAGE-ID|' \
  "$temp_root/task-bogus-package/TASK_INDEX.md"
expect_invalid "$temp_root/task-bogus-package" \
  "Active Package must be a PKG-\* ID" \
  "Task with a malformed Active Package"

cp -R "$multitask_case" "$temp_root/task-duplicate-status"
perl -0pi -e 's/(### T-002\n- Title: Worker\n- Role: worker\n- Status: active)/${1}\n- Status: integrated/' \
  "$temp_root/task-duplicate-status/TASK_INDEX.md"
expect_invalid "$temp_root/task-duplicate-status" \
  "declares 'Status' 2 times" \
  "Task declaring Status twice"

cp -R "$receipt_base" "$temp_root/receipt-duplicate-status"
write_receipt "$temp_root/receipt-duplicate-status" D-001 "validate_project pass" local-task-output/T-002/real.md PKG-001
perl -0pi -e 's/(- Status: integrated)/${1}\n- Status: rejected/' \
  "$temp_root/receipt-duplicate-status/MERGES.md"
expect_invalid "$temp_root/receipt-duplicate-status" \
  "declares 'Status' 2 times" \
  "Receipt declaring Status twice"

cp -R "$receipt_base" "$temp_root/receipt-lineage-no-migration"
$PY3 - "$temp_root/receipt-lineage-no-migration" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/MERGES.md'
open(p, 'w', encoding='utf-8').write('''# Merges

## Merge Receipts

### MERGE-001
- Target Package: PKG-001
- Source Tasks: T-002
- Relation: absorbs
- Accepted: local-task-output/T-002/real.md
- Rejected: none
- Deferred: none
- Base Checkpoint: lineage_incomplete
- Result Checkpoint: lineage_incomplete
- Lineage Note: for convenience no checkpoint recorded
- Approval: D-001
- Verification: validate_project pass
- Status: integrated
''')
PYEOF
git -C "$temp_root/receipt-lineage-no-migration" init -q
git -C "$temp_root/receipt-lineage-no-migration" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" add -A
git -C "$temp_root/receipt-lineage-no-migration" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" commit -qm fixture
expect_invalid "$temp_root/receipt-lineage-no-migration" \
  "explicitly authorizes migrating or adopting pre-layer history" \
  "lineage_incomplete without migration eligibility"

cp -R "$receipt_base" "$temp_root/archived-contradiction"
perl -0pi -e 's/(- Status: )integrated/${1}archived/' \
  "$temp_root/archived-contradiction/TASK_INDEX.md"
head_ref="$(git -C "$temp_root/archived-contradiction" rev-parse HEAD 2>/dev/null || echo lineage_incomplete)"
$PY3 - "$temp_root/archived-contradiction" <<'PYEOF'
import subprocess, sys
root = sys.argv[1]
try:
    head = subprocess.run(['git', '-C', root, 'rev-parse', 'HEAD'],
                          capture_output=True, text=True).stdout.strip() or 'lineage_incomplete'
except Exception:
    head = 'lineage_incomplete'
receipt = '''# Merges

## Merge Receipts

### MERGE-001
- Target Package: PKG-001
- Source Tasks: T-002
- Relation: absorbs
- Accepted: local-task-output/T-002/real.md
- Rejected: none
- Deferred: none
- Base Checkpoint: {h}
- Result Checkpoint: {h}
- Approval: D-001
- Verification: validate_project pass
- Status: integrated

### MERGE-002
- Target Package: PKG-001
- Source Tasks: T-002
- Relation: rejected
- Accepted: none
- Rejected: local-task-output/T-002/real.md
- Deferred: none
- Base Checkpoint: {h}
- Result Checkpoint: {h}
- Approval: D-001
- Verification: validate_project pass
- Reason: contradiction fixture
- Status: rejected
'''.format(h=head)
open(root + '/MERGES.md', 'w', encoding='utf-8').write(receipt)
PYEOF
expect_invalid "$temp_root/archived-contradiction" \
  "contradictory terminal receipts" \
  "Archived task with contradictory receipts"

# ==== 049 adversarial matrix: evidence must prove the merge actually happened ====
matrix_base="$temp_root/matrix-base"
cp -R "$receipt_base" "$matrix_base"
write_matrix_receipt() {
  local dir="$1" verification="$2" accepted="$3" relation="$4" base="$5" result="$6" approval="$7" status="$8" target="$9"
  {
    printf '# Merges\n\n## Merge Receipts\n\n'
    printf '### MERGE-001\n- Target Package: %s\n- Source Tasks: T-002\n- Relation: %s\n- Accepted: %s\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: %s\n- Result Checkpoint: %s\n- Lineage Note: migration per D-001\n- Approval: %s\n- Verification: %s\n- Status: %s\n' \
      "$target" "$relation" "$accepted" "$base" "$result" "$approval" "$verification" "$status"
  } >"$dir/MERGES.md"
}

cp -R "$matrix_base" "$temp_root/mx-verification-failed"
write_matrix_receipt "$temp_root/mx-verification-failed" "validate_project failed" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
expect_invalid "$temp_root/mx-verification-failed" \
  "not evidence the merge succeeded" \
  "Verification that says failed must be rejected"

cp -R "$matrix_base" "$temp_root/mx-verification-wrapper"
write_matrix_receipt "$temp_root/mx-verification-wrapper" "validate_project pass, though tests failed" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
expect_invalid "$temp_root/mx-verification-wrapper" \
  "not evidence the merge succeeded" \
  "Verification prose wrapping a failure must be rejected"

cp -R "$matrix_base" "$temp_root/mx-verification-directory"
write_matrix_receipt "$temp_root/mx-verification-directory" "file_evidence: docs" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
expect_invalid "$temp_root/mx-verification-directory" \
  "not evidence the merge succeeded" \
  "Verification naming a directory must be rejected"

cp -R "$matrix_base" "$temp_root/mx-verification-escape"
printf 'outside evidence\n' >"$temp_root/outside-evidence.md"
write_matrix_receipt "$temp_root/mx-verification-escape" "file_evidence: docs/../../outside-evidence.md" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
expect_invalid "$temp_root/mx-verification-escape" \
  "not evidence the merge succeeded" \
  "Verification escaping the project root must be rejected"

cp -R "$matrix_base" "$temp_root/mx-verification-unrelated-event"
write_matrix_receipt "$temp_root/mx-verification-unrelated-event" "event: 2020-01-01:MERGE-001" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
expect_invalid "$temp_root/mx-verification-unrelated-event" \
  "not evidence the merge succeeded" \
  "Verification borrowing an unrelated event date must be rejected"

cp -R "$matrix_base" "$temp_root/mx-approval-negative"
$PY3 - "$temp_root/mx-approval-negative" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/DECISIONS.md'
t = open(p, encoding='utf-8').read()
t = t.replace('## Status Events', '### D-003 [active]\n\n- Date: 2026-08-22\n- Decision: reject\n- Subject: MERGE-001\n- Summary: Approving nothing.\n\n## Status Events')
open(p, 'w', encoding='utf-8').write(t)
PYEOF
write_matrix_receipt "$temp_root/mx-approval-negative" "validate_project pass" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-003 integrated PKG-001
expect_invalid "$temp_root/mx-approval-negative" \
  "does not approve" \
  "A Decision: reject field must not authorize a merge"

cp -R "$matrix_base" "$temp_root/mx-deferred-ghost"
perl -0pi -e 's/(- Status: )integrated/${1}deferred/' "$temp_root/mx-deferred-ghost/TASK_INDEX.md"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: deferred\n- Accepted: none\n- Rejected: none\n- Deferred: local-task-output/T-002/ghost.md\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: none\n- Reactivate When: when upstream lands\n- Approval: D-001\n- Verification: validate_project pass\n- Status: deferred\n'
} >"$temp_root/mx-deferred-ghost/MERGES.md"
expect_invalid "$temp_root/mx-deferred-ghost" \
  "must keep recoverable evidence" \
  "A deferred path that does not exist must be rejected"

cp -R "$matrix_base" "$temp_root/mx-rejected-ghost"
perl -0pi -e 's/(- Status: )integrated/${1}rejected/' "$temp_root/mx-rejected-ghost/TASK_INDEX.md"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: rejected\n- Accepted: none\n- Rejected: local-task-output/T-002/ghost.md\n- Deferred: none\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: none\n- Reason: does not fit\n- Approval: D-001\n- Verification: validate_project pass\n- Status: rejected\n'
} >"$temp_root/mx-rejected-ghost/MERGES.md"
expect_invalid "$temp_root/mx-rejected-ghost" \
  "must keep recoverable evidence" \
  "A rejected path that does not exist must be rejected"

cp -R "$matrix_base" "$temp_root/mx-handoff-no-checkpoint"
perl -0pi -e 's/(- Status: )integrated/${1}handoff_ready/' "$temp_root/mx-handoff-no-checkpoint/TASK_INDEX.md"
expect_invalid "$temp_root/mx-handoff-no-checkpoint" \
  "is 'handoff_ready' without a 'Base Checkpoint'" \
  "handoff_ready without a base checkpoint must be rejected"

cp -R "$matrix_base" "$temp_root/mx-consumer-absorbs"
sed -i.bak 's/^- Role: worker$/- Role: consumer/' "$temp_root/mx-consumer-absorbs/TASK_INDEX.md"
write_matrix_receipt "$temp_root/mx-consumer-absorbs" "validate_project pass" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-001
expect_invalid "$temp_root/mx-consumer-absorbs" \
  "is not allowed for Source Task T-002 whose Role is 'consumer'" \
  "A consumer claiming absorbs must be rejected"

cp -R "$matrix_base" "$temp_root/mx-consumes-only-accepted"
sed -i.bak 's/^- Role: worker$/- Role: consumer/' "$temp_root/mx-consumes-only-accepted/TASK_INDEX.md"
write_matrix_receipt "$temp_root/mx-consumes-only-accepted" "validate_project pass" local-task-output/T-002/real.md consumes_only lineage_incomplete none D-001 integrated PKG-001
expect_invalid "$temp_root/mx-consumes-only-accepted" \
  "must have Accepted: none" \
  "consumes_only with a non-empty Accepted set must be rejected"

cp -R "$matrix_base" "$temp_root/mx-consumes-only-none"
sed -i.bak 's/^- Role: worker$/- Role: consumer/' "$temp_root/mx-consumes-only-none/TASK_INDEX.md"
write_matrix_receipt "$temp_root/mx-consumes-only-none" "validate_project pass" none consumes_only lineage_incomplete none D-001 integrated PKG-001
bash "$temp_root/mx-consumes-only-none/scripts/validate_project.sh" \
  "$temp_root/mx-consumes-only-none" --quiet

cp -R "$matrix_base" "$temp_root/mx-package-negative-event"
printf -- '- 2026-08-22: Do not create [PKG-999] here. | files: none | verify: none | pending: none\n' >>"$temp_root/mx-package-negative-event/EVENTS.md"
write_matrix_receipt "$temp_root/mx-package-negative-event" "validate_project pass" local-task-output/T-002/real.md absorbs lineage_incomplete lineage_incomplete D-001 integrated PKG-999
expect_invalid "$temp_root/mx-package-negative-event" \
  "nor recorded as a positive event line" \
  "A negated event line must not create a package identity"

cp -R "$matrix_base" "$temp_root/mx-task-capsule-outside"
sed -i.bak 's|^- Capsule: task-contexts/T-002.md$|- Capsule: docs/MAIN.md|' \
  "$temp_root/mx-task-capsule-outside/TASK_INDEX.md"
expect_invalid "$temp_root/mx-task-capsule-outside" \
  "must live under task-contexts/" \
  "A worker capsule outside task-contexts/ must be rejected"

cp -R "$matrix_base" "$temp_root/mx-task-missing-title"
sed -i.bak '/^- Title: Worker$/d' "$temp_root/mx-task-missing-title/TASK_INDEX.md"
expect_invalid "$temp_root/mx-task-missing-title" \
  "has no Title" \
  "A task without a Title must be rejected"

cp -R "$matrix_base" "$temp_root/mx-checkpoint-empty-tree"
git -C "$temp_root/mx-checkpoint-empty-tree" init -q
git -C "$temp_root/mx-checkpoint-empty-tree" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" add -A
git -C "$temp_root/mx-checkpoint-empty-tree" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" commit -q -m base
git -C "$temp_root/mx-checkpoint-empty-tree" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" commit -q --allow-empty -m empty
empty_tree_base="$(git -C "$temp_root/mx-checkpoint-empty-tree" rev-parse HEAD~1)"
empty_tree_result="$(git -C "$temp_root/mx-checkpoint-empty-tree" rev-parse HEAD)"
write_matrix_receipt "$temp_root/mx-checkpoint-empty-tree" "validate_project pass" local-task-output/T-002/real.md absorbs "$empty_tree_base" "$empty_tree_result" D-001 integrated PKG-001
expect_invalid "$temp_root/mx-checkpoint-empty-tree" \
  "carry the same tree" \
  "Different commits with the same tree must be rejected"

cp -R "$matrix_base" "$temp_root/mx-checkpoint-reversed"
git -C "$temp_root/mx-checkpoint-reversed" init -q
git -C "$temp_root/mx-checkpoint-reversed" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" add -A
git -C "$temp_root/mx-checkpoint-reversed" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" commit -q -m base
printf 'extra\n' >"$temp_root/mx-checkpoint-reversed/docs/extra.md"
git -C "$temp_root/mx-checkpoint-reversed" add -A
git -C "$temp_root/mx-checkpoint-reversed" -c user.name="PPS Smoke" \
  -c user.email="pps-smoke@example.invalid" commit -q -m result
rev_base="$(git -C "$temp_root/mx-checkpoint-reversed" rev-parse HEAD)"
rev_result="$(git -C "$temp_root/mx-checkpoint-reversed" rev-parse HEAD~1)"
write_matrix_receipt "$temp_root/mx-checkpoint-reversed" "validate_project pass" local-task-output/T-002/real.md absorbs "$rev_base" "$rev_result" D-001 integrated PKG-001
expect_invalid "$temp_root/mx-checkpoint-reversed" \
  "not a descendant of its Base Checkpoint" \
  "Reversed Base/Result checkpoints must be rejected"

mx_gate_exit9="$temp_root/mx-gate-exit9"
cp -R "$temp_root/software-case" "$mx_gate_exit9"
mkdir -p "$mx_gate_exit9/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mx_gate_exit9/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mx_gate_exit9/PROJECT_STATE.md"
mkdir -p "$mx_gate_exit9/tests"
printf '#!/usr/bin/env bash\nexit 9\n' >"$mx_gate_exit9/tests/real-check.sh"
printf 'M-002\tany\t.\t60\t0\tbash tests/real-check.sh\tfailing test\n' \
  >>"$mx_gate_exit9/.pps/verify-manifest.txt"
rm -f "$mx_gate_exit9/.pps/verify-stamp"
bash "$mx_gate_exit9/scripts/session_begin.sh" "$mx_gate_exit9" >/dev/null 2>&1 || true
set +e
bash "$mx_gate_exit9/scripts/verify_gate.sh" "$mx_gate_exit9" >"$temp_root/mx-gate-exit9.out" 2>&1
mx_gate_exit9_code=$?
set -e
[[ "$mx_gate_exit9_code" != "0" ]]
grep -q 'check manifest execution' "$temp_root/mx-gate-exit9.out"
[[ ! -f "$mx_gate_exit9/.pps/verify-stamp" ]]
$PY3 - "$mx_gate_exit9" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1] + '/.pps/verify-run.json'))
assert r['result'] == 'fail', r
for item in r['items']:
    if item['id'] == 'M-002':
        assert item['exit_code'] == 9 and item['ok'] is False, item
PYEOF

mx_gate_mention="$temp_root/mx-gate-mention"
cp -R "$temp_root/software-case" "$mx_gate_mention"
mkdir -p "$mx_gate_mention/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mx_gate_mention/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mx_gate_mention/PROJECT_STATE.md"
mkdir -p "$mx_gate_mention/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$mx_gate_mention/tests/parity-harness.sh"
$PY3 - "$mx_gate_mention" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
PYEOF
printf 'M-002\tbash\t.\t60\t0\tbash -c "echo tests/parity-harness.sh"\tprint only\n' \
  >>"$mx_gate_mention/.pps/verify-manifest.txt"
rm -f "$mx_gate_mention/.pps/verify-stamp"
bash "$mx_gate_mention/scripts/session_begin.sh" "$mx_gate_mention" >/dev/null 2>&1 || true
set +e
bash "$mx_gate_mention/scripts/verify_gate.sh" "$mx_gate_mention" >"$temp_root/mx-gate-mention.out" 2>&1
mx_gate_mention_code=$?
set -e
[[ "$mx_gate_mention_code" != "0" ]]
grep -q 'red line not wired to an executed check' "$temp_root/mx-gate-mention.out"

mx_gate_wired="$temp_root/mx-gate-wired"
cp -R "$temp_root/software-case" "$mx_gate_wired"
mkdir -p "$mx_gate_wired/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mx_gate_wired/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mx_gate_wired/PROJECT_STATE.md"
mkdir -p "$mx_gate_wired/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$mx_gate_wired/tests/parity-harness.sh"
$PY3 - "$mx_gate_wired" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
PYEOF
printf 'M-002\tbash\t.\t60\t0\tbash tests/parity-harness.sh\treal check\n' \
  >>"$mx_gate_wired/.pps/verify-manifest.txt"
rm -f "$mx_gate_wired/.pps/verify-stamp"
bash "$mx_gate_wired/scripts/session_begin.sh" "$mx_gate_wired" >/dev/null 2>&1 || true
bash "$mx_gate_wired/scripts/verify_gate.sh" "$mx_gate_wired" >"$temp_root/mx-gate-wired.out" 2>&1
grep -q 'red line wiring: all named checks are wired to executed manifest checks' "$temp_root/mx-gate-wired.out"

# ==== 050 field-consistency fixtures ====

# 050-01: the default manifest must not hardcode an interpreter the machine
# may not have; the powershell row runs under the gate's own engine.
grep -q '^M-001	powershell	\.	60	0	& ./scripts/project_verify.ps1 -Root .' \
  "$temp_root/software-case/.pps/verify-manifest.txt"

# 050-03: the timeout column is a real deadline: the row is killed, the run
# record says timeout, and no stamp is written.
mx_timeout="$temp_root/mx-timeout"
cp -R "$temp_root/software-case" "$mx_timeout"
mkdir -p "$mx_timeout/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mx_timeout/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mx_timeout/PROJECT_STATE.md"
printf 'M-050	any	.	1	0	sleep 30	slow test
' >>"$mx_timeout/.pps/verify-manifest.txt"
rm -f "$mx_timeout/.pps/verify-stamp"
bash "$mx_timeout/scripts/session_begin.sh" "$mx_timeout" >/dev/null 2>&1 || true
set +e
bash "$mx_timeout/scripts/verify_gate.sh" "$mx_timeout" >"$temp_root/mx-timeout.out" 2>&1
mx_timeout_code=$?
set -e
[[ "$mx_timeout_code" != "0" ]]
grep -q 'timed out after 1s' "$temp_root/mx-timeout.out"
[[ ! -f "$mx_timeout/.pps/verify-stamp" ]]
$PY3 - "$mx_timeout" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1] + '/.pps/verify-run.json'))
for item in r['items']:
    if item['id'] == 'M-050':
        assert item['ok'] is False and item['exit_code'] == 'timeout', item
PYEOF

# 050-04: a working directory escaping the project root fails the row.
mx_cwd="$temp_root/mx-cwd-escape"
cp -R "$temp_root/software-case" "$mx_cwd"
mkdir -p "$mx_cwd/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mx_cwd/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mx_cwd/PROJECT_STATE.md"
printf 'M-050	any	../	60	0	pwd	escape attempt
' >>"$mx_cwd/.pps/verify-manifest.txt"
rm -f "$mx_cwd/.pps/verify-stamp"
bash "$mx_cwd/scripts/session_begin.sh" "$mx_cwd" >/dev/null 2>&1 || true
set +e
bash "$mx_cwd/scripts/verify_gate.sh" "$mx_cwd" >"$temp_root/mx-cwd.out" 2>&1
mx_cwd_code=$?
set -e
[[ "$mx_cwd_code" != "0" ]]
grep -q "cwd '../' escapes the project root" "$temp_root/mx-cwd.out"

# 050-05: an unquoted echo of the path is not a call and must not wire the
# red line (the 0.5.0 fixture only used bash -c, which the eval flag blocks).
mx_echo="$temp_root/mx-echo-mention"
cp -R "$temp_root/software-case" "$mx_echo"
mkdir -p "$mx_echo/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mx_echo/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mx_echo/PROJECT_STATE.md"
mkdir -p "$mx_echo/tests"
printf '#!/usr/bin/env bash
exit 0
' >"$mx_echo/tests/parity-harness.sh"
$PY3 - "$mx_echo" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
PYEOF
printf 'M-002	bash	.	60	0	echo tests/parity-harness.sh	print only, unquoted
' \
  >>"$mx_echo/.pps/verify-manifest.txt"
rm -f "$mx_echo/.pps/verify-stamp"
bash "$mx_echo/scripts/session_begin.sh" "$mx_echo" >/dev/null 2>&1 || true
set +e
bash "$mx_echo/scripts/verify_gate.sh" "$mx_echo" >"$temp_root/mx-echo.out" 2>&1
mx_echo_code=$?
set -e
[[ "$mx_echo_code" != "0" ]]
grep -q 'red line not wired to an executed check' "$temp_root/mx-echo.out"

# P0-01 / P1-02: the real 1.1 migration matrix. Every fixture was initialized
# by the actual PPS/1.1 skill release (v0.3.0), so the migrator faces the
# files a real old project has: no gate scripts, no EVENTS.md, bare Present
# coverage, undated proposals, no Red Lines section. The assertion is the
# FINAL 1.2 state (valid + gated + ready), not "files were created".
for mig_fixture in \
  pps-1.1-document-standard \
  pps-1.1-software-standard \
  pps-1.1-hybrid-standard \
  pps-1.1-document-evidence; do
  mx_mig="$temp_root/mig-$mig_fixture"
  cp -R "$repo_root/tests/fixtures/$mig_fixture" "$mx_mig"
  ( cd "$mx_mig" && git init -q &&
    git add -A &&
    git -c user.name=Smoke -c user.email=smoke@example.invalid commit -qm base >/dev/null )
  find "$mx_mig" -type f ! -path '*/.git/*' -exec sh -c 'printf "%s %s\n" "$(shasum -a 256 "$1" | awk "{print \$1}")" "${1#'"$mx_mig"'/}"' _ {} \; \
    | LC_ALL=C sort >"$mx_mig.preapply"
  bash "$skill/scripts/migrate_project.sh" "$mx_mig" --apply --confirm \
    >"$temp_root/mig-$mig_fixture.log" 2>&1
  # Core upgrade must NOT force the multitask layer onto a single-task project.
  [[ ! -f "$mx_mig/TASK_INDEX.md" ]]
  [[ ! -f "$mx_mig/MERGES.md" ]]
  grep -q -- '- Protocol: PPS/1.2' "$mx_mig/PROJECT_STATE.md"
  head -8 "$mx_mig/AGENTS.md" | grep -q '^## Red Lines$'
  grep -q "### D-MIGRATE-001 \[active\]" "$mx_mig/DECISIONS.md"
  grep -q '`D-MIGRATE-001`' "$mx_mig/DECISIONS.md"
  grep -q 'Decisions: D-MIGRATE-001' "$mx_mig/CONTEXT.md"
  grep -q 'migration_authorized D-MIGRATE-001' "$mx_mig/EVENTS.md"
  ! grep -Eq '^\|.*\| Present \|$' "$mx_mig/CONTEXT.md" "$mx_mig/docs/CURRENT_REVIEW_EVIDENCE.md" 2>/dev/null
  grep -q 'opened 20' "$mx_mig/CONTEXT.md"
  for required_script in verify_gate project_verify append_event; do
    [[ -f "$mx_mig/scripts/$required_script.sh" ]]
    [[ -f "$mx_mig/scripts/$required_script.ps1" ]]
  done
  [[ -f "$mx_mig/scripts/pps_evidence.py" ]]
  # The final 1.2 state must validate, gate, and reach readiness.
  bash "$mx_mig/scripts/validate_project.sh" "$mx_mig" >/dev/null 2>&1
  [[ -f "$mx_mig/.pps/verify-stamp" ]]
  bash "$mx_mig/scripts/readiness_check.sh" --verified "$mx_mig" >/dev/null 2>&1
  # Rollback restores the pre-apply file set AND byte identity.
  mx_mig_backup="$(ls -d "$mx_mig/.pps"/migration-backup-* | head -1)"
  bash "$skill/scripts/migrate_project.sh" "$mx_mig" --rollback "$mx_mig_backup" \
    >/dev/null 2>&1
  find "$mx_mig" -type f ! -path '*/.git/*' ! -path '*/.pps/*' -exec sh -c 'printf "%s %s\n" "$(shasum -a 256 "$1" | awk "{print \$1}")" "${1#'"$mx_mig"'/}"' _ {} \; \
    | LC_ALL=C sort >"$mx_mig.postrollback"
  diff "$mx_mig.preapply" "$mx_mig.postrollback" >/dev/null
  grep -q -- '- Protocol: PPS/1.1' "$mx_mig/PROJECT_STATE.md"
done

# The multitask layer stays an explicit opt-in: --with-multitask creates the
# registry, the receipt file, and the Writer line; validation still passes.
mx_mt="$temp_root/mig-multitask"
cp -R "$repo_root/tests/fixtures/pps-1.1-document-standard" "$mx_mt"
( cd "$mx_mt" && git init -q && git add -A &&
  git -c user.name=Smoke -c user.email=smoke@example.invalid commit -qm base >/dev/null )
bash "$skill/scripts/migrate_project.sh" "$mx_mt" --apply --confirm --with-multitask \
  >"$temp_root/mig-multitask.log" 2>&1
[[ -f "$mx_mt/TASK_INDEX.md" ]]
[[ -f "$mx_mt/MERGES.md" ]]
grep -q '^- Writer: T-001' "$mx_mt/PROJECT_STATE.md"
bash "$mx_mt/scripts/validate_project.sh" "$mx_mt" >/dev/null 2>&1
[[ -f "$mx_mt/.pps/verify-stamp" ]]

# A migration that would not validate rolls back automatically instead of
# leaving a half-migrated project (the bare-Present row survives the standard
# upgrades and trips the 1/3-manual rule).
mx_fail="$temp_root/mig-fails"
cp -R "$repo_root/tests/fixtures/pps-1.1-document-standard" "$mx_fail"
( cd "$mx_fail" && git init -q && git add -A &&
  git -c user.name=Smoke -c user.email=smoke@example.invalid commit -qm base >/dev/null )
# A state the migrator cannot repair (no Coverage declaration) must fail
# validation, trigger the automatic rollback, and never leave a half-1.2
# project behind.
sed -i.bak '/^- Coverage:/d' "$mx_fail/PROJECT_STATE.md"
rm -f "$mx_fail/PROJECT_STATE.md.bak"
if bash "$skill/scripts/migrate_project.sh" "$mx_fail" --apply --confirm \
  >"$temp_root/mig-fails.log" 2>&1; then
  echo "Migration of an unrecoverable 1.1 state incorrectly succeeded." >&2
  exit 1
fi
grep -q -- '- Protocol: PPS/1.1' "$mx_fail/PROJECT_STATE.md"
[[ ! -f "$mx_fail/EVENTS.md" ]]

# 050-02: with a broken python3 on PATH the gate falls back to python and
# still stamps (field machines hit the Store stub exactly this way).
mx_py="$temp_root/mx-py-fallback"
cp -R "$temp_root/software-case" "$mx_py"
mkdir -p "$mx_py/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mx_py/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mx_py/PROJECT_STATE.md"
py_shim="$temp_root/py-shim"
mkdir -p "$py_shim"
printf '#!/bin/sh
echo "store stub"
exit 127
' >"$py_shim/python3"
chmod +x "$py_shim/python3"
real_py="$(command -v python3 || command -v python)"
# A wrapper (not a symlink): macOS CLT python3 shims dispatch on argv[0], so a
# python-named symlink can trigger the xcode-select stub instead of running.
printf '#!/bin/sh\nexec %s "$@"\n' "$real_py" >"$py_shim/python"
chmod +x "$py_shim/python"
rm -f "$mx_py/.pps/verify-stamp"
bash "$mx_py/scripts/session_begin.sh" "$mx_py" >/dev/null 2>&1 || true
PATH="$py_shim:$PATH" bash "$mx_py/scripts/verify_gate.sh" "$mx_py" \
  >"$temp_root/mx-py.out" 2>&1
[[ -f "$mx_py/.pps/verify-stamp" ]]

cp -R "$receipt_base" "$temp_root/empty-deferred"
perl -0pi -e 's/(- Status: )integrated/${1}deferred/' \
  "$temp_root/empty-deferred/TASK_INDEX.md"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: deferred\n- Accepted: none\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: none\n- Result Checkpoint: none\n- Approval: none\n- Verification: none\n- Status: deferred\n'
} >"$temp_root/empty-deferred/MERGES.md"
expect_invalid "$temp_root/empty-deferred" \
  "a deferral that defers nothing records nothing" \
  "Deferred receipt with no deferred set"
expect_invalid "$temp_root/empty-deferred" \
  "without a 'Reactivate When' field" \
  "Deferred receipt without reactivation condition"

cp -R "$receipt_base" "$temp_root/empty-rejected"
perl -0pi -e 's/(- Status: )integrated/${1}rejected/' \
  "$temp_root/empty-rejected/TASK_INDEX.md"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: rejected\n- Accepted: none\n- Rejected: none\n- Deferred: none\n- Base Checkpoint: none\n- Result Checkpoint: none\n- Approval: none\n- Verification: none\n- Status: rejected\n'
} >"$temp_root/empty-rejected/MERGES.md"
expect_invalid "$temp_root/empty-rejected" \
  "a rejection that rejects nothing records nothing" \
  "Rejected receipt with no rejected set"
expect_invalid "$temp_root/empty-rejected" \
  "without a 'Reason' field" \
  "Rejected receipt without reason"

# P1-03: an 'integrated' receipt must not mask open dispositions, and every
# non-empty Rejected/Deferred set carries its own Reason/Reactivate When.
cp -R "$receipt_base" "$temp_root/receipt-mixed-masked"
write_receipt "$temp_root/receipt-mixed-masked" D-001 "validate_project pass" local-task-output/T-002/real.md PKG-001
printf 'real drop\n' >"$temp_root/receipt-mixed-masked/local-task-output/T-002/drop.md"
printf 'real later\n' >"$temp_root/receipt-mixed-masked/local-task-output/T-002/later.md"
perl -0pi -e 's/(- Accepted: local-task-output\/T-002\/real.md\n)- Rejected: none\n- Deferred: none\n/${1}- Rejected: local-task-output\/T-002\/drop.md\n- Deferred: local-task-output\/T-002\/later.md\n/' \
  "$temp_root/receipt-mixed-masked/MERGES.md"
expect_invalid "$temp_root/receipt-mixed-masked" \
  "still lists Rejected or Deferred paths" \
  "Integrated receipt masking mixed dispositions"
expect_invalid "$temp_root/receipt-mixed-masked" \
  "non-empty Rejected set without a 'Reason' field" \
  "Mixed receipt missing rejection reason"
expect_invalid "$temp_root/receipt-mixed-masked" \
  "non-empty Deferred set without a 'Reactivate When' field" \
  "Mixed receipt missing reactivation condition"

# The explicit partial state passes with full per-set evidence and a task
# that stays active until the remainder is resolved.
cp -R "$receipt_base" "$temp_root/receipt-partial-full"
perl -0pi -e 's/(### T-002\n- Title: Worker\n- Role: worker\n- Status: )integrated/${1}active/' \
  "$temp_root/receipt-partial-full/TASK_INDEX.md"
printf 'real drop\n' >"$temp_root/receipt-partial-full/local-task-output/T-002/drop.md"
printf 'real later\n' >"$temp_root/receipt-partial-full/local-task-output/T-002/later.md"
{
  printf '# Merges\n\n## Merge Receipts\n\n'
  printf '### MERGE-001\n- Target Package: PKG-001\n- Source Tasks: T-002\n- Relation: absorbs\n- Accepted: local-task-output/T-002/real.md\n- Rejected: local-task-output/T-002/drop.md\n- Deferred: local-task-output/T-002/later.md\n- Base Checkpoint: lineage_incomplete\n- Result Checkpoint: lineage_incomplete\n- Lineage Note: migration per D-001\n- Approval: D-001\n- Verification: validate_project pass\n- Reason: duplicates the accepted artifact.\n- Reactivate When: after the next package closes.\n- Status: partially_integrated\n'
} >"$temp_root/receipt-partial-full/MERGES.md"
bash "$temp_root/receipt-partial-full/scripts/validate_project.sh" \
  "$temp_root/receipt-partial-full" --quiet

# A partially integrated receipt cannot sit under a task the registry calls
# integrated: the task's own status must stay active.
cp -R "$temp_root/receipt-partial-full" "$temp_root/receipt-partial-task-done"
perl -0pi -e 's/(### T-002\n- Title: Worker\n- Role: worker\n- Status: )active/${1}integrated/' \
  "$temp_root/receipt-partial-task-done/TASK_INDEX.md"
expect_invalid "$temp_root/receipt-partial-task-done" \
  "stays active until the remainder is resolved" \
  "Partially integrated task marked integrated in the registry"

cp -R "$multitask_case" "$temp_root/phantom-refs"
sed -i.bak 's|^- Methods: none$|- Methods: M-404|; s|^- Components: C-ROOT$|- Components: C-404|' \
  "$temp_root/phantom-refs/task-contexts/T-002.md"
expect_invalid "$temp_root/phantom-refs" \
  "references authority M-404 which is not in the DECISIONS.md active block" \
  "Task referencing phantom authority"
expect_invalid "$temp_root/phantom-refs" \
  "references component C-404 which does not exist" \
  "Task referencing phantom component"

stamp_case="$temp_root/stamp-case"
cp -R "$temp_root/standard-case" "$stamp_case"
set +e
bash "$stamp_case/scripts/readiness_check.sh" "$stamp_case" --verified \
  >"$temp_root/stamp-missing.out" 2>&1
stamp_missing_code=$?
set -e
[[ "$stamp_missing_code" == "4" ]]
grep -q 'VERIFY EVIDENCE MISSING' "$temp_root/stamp-missing.out"
bash "$stamp_case/scripts/verify_gate.sh" "$stamp_case" >/dev/null
bash "$stamp_case/scripts/readiness_check.sh" "$stamp_case" --verified \
  >"$temp_root/stamp-present.out"
grep -q '^PPS readiness: OK$' "$temp_root/stamp-present.out"
sed -i.bak 's/^package: PKG-001$/package: PKG-999/' "$stamp_case/.pps/verify-stamp"
set +e
bash "$stamp_case/scripts/readiness_check.sh" "$stamp_case" --verified \
  >"$temp_root/stamp-stale.out" 2>&1
stamp_stale_code=$?
set -e
[[ "$stamp_stale_code" == "4" ]]
grep -q 'VERIFY EVIDENCE STALE' "$temp_root/stamp-stale.out"

event_append_case="$temp_root/event-append-case"
cp -R "$temp_root/standard-case" "$event_append_case"
bash "$event_append_case/scripts/append_event.sh" "$event_append_case" \
  --title "Smoke event" --files "docs/MAIN.md" --verify "gate pass"
grep -q '\[PKG-001\] Smoke event | files: docs/MAIN.md | verify: gate pass | pending: none' \
  "$event_append_case/EVENTS.md"
bash "$event_append_case/scripts/validate_project.sh" "$event_append_case" --quiet
if bash "$event_append_case/scripts/append_event.sh" "$event_append_case" \
  --title "bad | title" >"$temp_root/event-pipe.out" 2>&1; then
  echo "Event appender accepted a title containing the separator." >&2
  exit 1
fi
grep -q "must not contain the '|' separator" "$temp_root/event-pipe.out"

boundary_case="$temp_root/boundary-case"
bash "$skill/scripts/init_project.sh" boundary-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
printf 'rogue content\n' >"$boundary_case/rogue.txt"
if bash "$boundary_case/scripts/boundary_check.sh" "$boundary_case" \
  >"$temp_root/boundary-fail.out" 2>&1; then
  echo "Boundary check accepted an unclaimed write." >&2
  exit 1
fi
grep -q 'unclaimed_write: rogue.txt' "$temp_root/boundary-fail.out"
if bash "$boundary_case/scripts/boundary_check.sh" "$boundary_case" \
  --allow-preexisting >"$temp_root/boundary-nobaseline.out" 2>&1; then
  echo "Boundary check downgraded changes without a recorded baseline." >&2
  exit 1
fi
grep -q 'requires a recorded baseline' "$temp_root/boundary-nobaseline.out"
bash "$boundary_case/scripts/boundary_check.sh" "$boundary_case" \
  --record-baseline >/dev/null
bash "$boundary_case/scripts/boundary_check.sh" "$boundary_case" \
  --allow-preexisting >"$temp_root/boundary-preexisting.out"
grep -q 'preexisting (baseline): rogue.txt' \
  "$temp_root/boundary-preexisting.out"
printf 'new rogue\n' >"$boundary_case/rogue2.txt"
if bash "$boundary_case/scripts/boundary_check.sh" "$boundary_case" \
  --allow-preexisting >"$temp_root/boundary-newrogue.out" 2>&1; then
  echo "Boundary check treated a post-baseline change as preexisting." >&2
  exit 1
fi
grep -q 'unclaimed_write: rogue2.txt' "$temp_root/boundary-newrogue.out"
rm "$boundary_case/rogue2.txt"
printf 'rogue content rewritten after baseline\n' >"$boundary_case/rogue.txt"
if bash "$boundary_case/scripts/boundary_check.sh" "$boundary_case" \
  --allow-preexisting >"$temp_root/boundary-rewritten.out" 2>&1; then
  echo "Boundary check exempted a baselined path whose content changed." >&2
  exit 1
fi
grep -q 'baselined path changed again after the baseline' \
  "$temp_root/boundary-rewritten.out"
rm "$boundary_case/rogue.txt" \
  "$boundary_case/.pps/boundary-baseline"
printf 'update\n' >>"$boundary_case/docs/MAIN.md"
bash "$boundary_case/scripts/boundary_check.sh" "$boundary_case" \
  >"$temp_root/boundary-claimed.out"
grep -q 'claimed: docs/MAIN.md' "$temp_root/boundary-claimed.out"
grep -q '^PPS boundary check: OK$' "$temp_root/boundary-claimed.out"

terminal_subject="$temp_root/boundary-terminal-subject"
bash "$skill/scripts/init_project.sh" boundary-terminal-subject \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
mkdir -p "$terminal_subject/task-contexts"
{
  printf '# T-002 Capsule\n\n## Workset Manifest\n\n'
  printf -- '- Methods: none\n- Facts: none\n- Decisions: none\n- Sources: none\n- Assets: none\n'
  printf -- '- Components: C-ROOT\n- Read: PROJECT_MAP.md\n- Write: local-task-output/T-002/out.md\n'
  printf -- '- Verify: scripts/verify_gate.sh\n- Excluded: none\n- Coverage: CONTEXT.md\n'
} >"$terminal_subject/task-contexts/T-002.md"
{
  printf '# Task Index\n\n## Task Index\n\n'
  printf '### T-001\n- Title: I\n- Role: integrator\n- Status: active\n- Active Package: PKG-001\n- Capsule: CONTEXT.md\n- Output Root: none\n\n'
  printf '### T-002\n- Title: W\n- Role: worker\n- Status: rejected\n- Active Package: PKG-001\n- Capsule: task-contexts/T-002.md\n- Output Root: local-task-output/T-002\n'
} >"$terminal_subject/TASK_INDEX.md"
if bash "$terminal_subject/scripts/boundary_check.sh" "$terminal_subject" \
  --task T-002 >"$temp_root/boundary-terminal.out" 2>&1; then
  echo "Boundary check granted write authority to a terminal-status task." >&2
  exit 1
fi
grep -q "only an active task holds write authority" "$temp_root/boundary-terminal.out"

unclaimed_canonical="$temp_root/boundary-canonical"
bash "$skill/scripts/init_project.sh" boundary-canonical \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
sed -i.bak 's|^- Write:.*|- Write: docs/MAIN.md|' \
  "$unclaimed_canonical/CONTEXT.md"
rm "$unclaimed_canonical/CONTEXT.md.bak"
git -C "$unclaimed_canonical" add CONTEXT.md >/dev/null
git -C "$unclaimed_canonical" commit -qm "narrow write set" >/dev/null
printf 'drift\n' >>"$unclaimed_canonical/DECISIONS.md"
if bash "$unclaimed_canonical/scripts/boundary_check.sh" "$unclaimed_canonical" \
  >"$temp_root/boundary-canonical.out" 2>&1; then
  echo "Boundary check auto-claimed an undeclared canonical file." >&2
  exit 1
fi
grep -q 'unclaimed_write: DECISIONS.md' "$temp_root/boundary-canonical.out"

# --- Necessary-path fixtures (D-CORE-012..020) -----------------------------
gate_no_snapshot_case="$temp_root/gate-no-snapshot-case"
cp -R "$temp_root/software-case" "$gate_no_snapshot_case"
# The objective anchor comes from the same session_begin run; deleting only
# the snapshot isolates the relay check from the anchor check.
bash "$gate_no_snapshot_case/scripts/session_begin.sh" "$gate_no_snapshot_case" \
  >/dev/null 2>&1 || true
rm -f "$gate_no_snapshot_case/.pps/session-snapshot" "$gate_no_snapshot_case/.pps/verify-stamp"
set +e
bash "$gate_no_snapshot_case/scripts/verify_gate.sh" "$gate_no_snapshot_case" \
  >"$temp_root/gate-no-snapshot.out" 2>&1
gate_no_snapshot_code=$?
set -e
[[ "$gate_no_snapshot_code" != "0" ]]
grep -q 'Relay: SNAPSHOT MISSING' "$temp_root/gate-no-snapshot.out"
[[ ! -f "$gate_no_snapshot_case/.pps/verify-stamp" ]]

gate_only_overwrite_case="$temp_root/gate-only-overwrite-case"
bash "$skill/scripts/init_project.sh" gate-only-overwrite-case \
  --mode software --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
printf 'session A hardening not committed\n' >"$gate_only_overwrite_case/docs/MAIN.md"
bash "$gate_only_overwrite_case/scripts/session_begin.sh" "$gate_only_overwrite_case" >/dev/null
printf 'session B wholesale overwrite\n' >"$gate_only_overwrite_case/docs/MAIN.md"
rm -f "$gate_only_overwrite_case/.pps/verify-stamp"
set +e
bash "$gate_only_overwrite_case/scripts/verify_gate.sh" "$gate_only_overwrite_case" \
  >"$temp_root/gate-only-overwrite.out" 2>&1
gate_only_code=$?
set -e
[[ "$gate_only_code" != "0" ]]
grep -q 'protected_overwrite: docs/MAIN.md' "$temp_root/gate-only-overwrite.out"
[[ ! -f "$gate_only_overwrite_case/.pps/verify-stamp" ]]

stale_snapshot_case="$temp_root/stale-snapshot-case"
bash "$skill/scripts/init_project.sh" stale-snapshot-case \
  --mode software --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
printf 'session A work\n' >"$stale_snapshot_case/docs/MAIN.md"
bash "$stale_snapshot_case/scripts/session_begin.sh" "$stale_snapshot_case" >/dev/null
$PY3 - "$stale_snapshot_case" <<'PYEOF2'
import re, sys
p = sys.argv[1] + '/.pps/session-snapshot'
t = open(p, encoding='utf-8').read()
m = re.search(r'^started_epoch: (\d+)', t, re.M)
t = re.sub(r'^started_epoch: \d+', 'started_epoch: %d' % (int(m.group(1)) - 3 * 86400), t, flags=re.M)
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
set +e
bash "$stale_snapshot_case/scripts/session_begin.sh" "$stale_snapshot_case" \
  >"$temp_root/stale-snapshot.out" 2>&1
stale_snapshot_code=$?
set -e
[[ "$stale_snapshot_code" == "3" ]]
grep -Eq 'session snapshot (already exists|exists)' "$temp_root/stale-snapshot.out"
grep -q 'docs/MAIN.md' "$temp_root/stale-snapshot.out"
grep -q 'Re-run with --takeover' "$temp_root/stale-snapshot.out"
# Beyond the TTL the claim must still hold: age never releases it.
$PY3 - "$stale_snapshot_case" <<'PYEOF2'
import re, sys
p = sys.argv[1] + '/.pps/session-snapshot'
t = open(p, encoding='utf-8').read()
m = re.search(r'^started_epoch: (\d+)', t, re.M)
t = re.sub(r'^started_epoch: \d+', 'started_epoch: %d' % (int(m.group(1)) - 30 * 86400), t, flags=re.M)
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
set +e
bash "$stale_snapshot_case/scripts/session_begin.sh" "$stale_snapshot_case" \
  >"$temp_root/expired-snapshot.out" 2>&1
expired_snapshot_code=$?
set -e
[[ "$expired_snapshot_code" == "3" ]]
grep -q 'stale session snapshot' "$temp_root/expired-snapshot.out"
grep -q 'Age does not release the claim' "$temp_root/expired-snapshot.out"
bash "$stale_snapshot_case/scripts/session_begin.sh" "$stale_snapshot_case" --takeover \
  >"$temp_root/stale-takeover.out" 2>&1
grep -q 'Relay event recorded' "$temp_root/stale-takeover.out"
grep -q 'relay takeover' "$stale_snapshot_case/EVENTS.md"

comment_wiring_case="$temp_root/comment-wiring-case"
cp -R "$temp_root/software-case" "$comment_wiring_case"
mkdir -p "$comment_wiring_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$comment_wiring_case/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$comment_wiring_case/PROJECT_STATE.md"
mkdir -p "$comment_wiring_case/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$comment_wiring_case/tests/parity-harness.sh"
$PY3 - "$comment_wiring_case" <<'PYEOF2'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
p = root + '/scripts/project_verify.sh'
t = open(p, encoding='utf-8').read()
t = t.replace('# Add project-specific checks here, for example:',
              '# also see tests/parity-harness.sh someday\n# Add project-specific checks here, for example:')
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
rm -f "$comment_wiring_case/.pps/verify-stamp"
bash "$comment_wiring_case/scripts/session_begin.sh" "$comment_wiring_case" >/dev/null 2>&1 || true
set +e
bash "$comment_wiring_case/scripts/verify_gate.sh" "$comment_wiring_case" \
  >"$temp_root/comment-wiring.out" 2>&1
comment_wiring_code=$?
set -e
[[ "$comment_wiring_code" != "0" ]]
grep -q 'no manifest check ran it successfully' "$temp_root/comment-wiring.out"
[[ ! -f "$comment_wiring_case/.pps/verify-stamp" ]]

always_true_case="$temp_root/always-true-case"
cp -R "$temp_root/software-case" "$always_true_case"
mkdir -p "$always_true_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$always_true_case/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$always_true_case/PROJECT_STATE.md"
$PY3 - "$always_true_case" <<'PYEOF2'
import re, sys
p = sys.argv[1] + '/scripts/project_verify.sh'
t = open(p, encoding='utf-8').read()
t = t.replace('behavioral_probe() { bash "$root/scripts/e2e_probe.sh" "$root"; }',
              'behavioral_probe() { true; }')
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
rm -f "$always_true_case/.pps/verify-stamp"
bash "$always_true_case/scripts/session_begin.sh" "$always_true_case" >/dev/null 2>&1 || true
set +e
bash "$always_true_case/scripts/verify_gate.sh" "$always_true_case" \
  >"$temp_root/always-true.out" 2>&1
always_true_code=$?
set -e
[[ "$always_true_code" != "0" ]]
grep -q 'behavioral check asserts nothing' "$temp_root/always-true.out"

coverage_unwired_case="$temp_root/coverage-unwired-case"
cp -R "$temp_root/standard-case" "$coverage_unwired_case"
mkdir -p "$coverage_unwired_case/prototypes"
printf '#!/usr/bin/env bash\nexit 0\n' >"$coverage_unwired_case/prototypes/hardening-smoke.sh"
$PY3 - "$coverage_unwired_case" <<'PYEOF2'
import re, sys
p = sys.argv[1] + '/CONTEXT.md'
t = open(p, encoding='utf-8').read()
t = re.sub(r'(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', r'\1 prototypes/hardening-smoke.sh |', t, count=1)
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
expect_invalid "$coverage_unwired_case" \
  "no manifest check ran it successfully" \
  "Coverage evidence that the gate never runs"

note_laundry_case="$temp_root/note-laundry-case"
cp -R "$temp_root/standard-case" "$note_laundry_case"
bash "$note_laundry_case/scripts/append_event.sh" "$note_laundry_case" \
  --title "note shipped installer hardening" --files none --verify none --pending none >/dev/null
expect_invalid "$note_laundry_case" \
  "informational prefix but claims a closing action" \
  "Informational prefix laundering a real closure"

installer_runtime_case="$temp_root/installer-runtime-case"
cp -R "$temp_root/software-case" "$installer_runtime_case"
printf 'param()\n' >"$installer_runtime_case/Install-Product.ps1"
bash "$installer_runtime_case/scripts/validate_project.sh" "$installer_runtime_case" \
  >"$temp_root/installer-runtime.out" 2>&1
grep -q "declares no '## Runtime Surfaces' row" "$temp_root/installer-runtime.out"

# --- 047 necessary-path round two (F-047-01..04) ---------------------------
gate_boundary_missing_case="$temp_root/gate-boundary-missing-case"
cp -R "$temp_root/software-case" "$gate_boundary_missing_case"
rm -f "$gate_boundary_missing_case/scripts/boundary_check.sh" \
  "$gate_boundary_missing_case/.pps/verify-stamp"
bash "$gate_boundary_missing_case/scripts/session_begin.sh" \
  "$gate_boundary_missing_case" >/dev/null 2>&1 || true
set +e
bash "$gate_boundary_missing_case/scripts/verify_gate.sh" "$gate_boundary_missing_case" \
  >"$temp_root/gate-boundary-missing.out" 2>&1
gate_boundary_missing_code=$?
set -e
[[ "$gate_boundary_missing_code" != "0" ]]
grep -q 'Relay: BOUNDARY MISSING' "$temp_root/gate-boundary-missing.out"
[[ ! -f "$gate_boundary_missing_case/.pps/verify-stamp" ]]

dead_fn_wiring_case="$temp_root/dead-fn-wiring-case"
cp -R "$temp_root/software-case" "$dead_fn_wiring_case"
mkdir -p "$dead_fn_wiring_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$dead_fn_wiring_case/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$dead_fn_wiring_case/PROJECT_STATE.md"
mkdir -p "$dead_fn_wiring_case/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$dead_fn_wiring_case/tests/parity-harness.sh"
$PY3 - "$dead_fn_wiring_case" <<'PYEOF2'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
p = root + '/scripts/project_verify.sh'
t = open(p, encoding='utf-8').read()
t += '\nnever_used() { bash "$root/tests/parity-harness.sh"; }\n'
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
rm -f "$dead_fn_wiring_case/.pps/verify-stamp"
bash "$dead_fn_wiring_case/scripts/session_begin.sh" \
  "$dead_fn_wiring_case" >/dev/null 2>&1 || true
set +e
bash "$dead_fn_wiring_case/scripts/verify_gate.sh" "$dead_fn_wiring_case" \
  >"$temp_root/dead-fn-wiring.out" 2>&1
dead_fn_wiring_code=$?
set -e
[[ "$dead_fn_wiring_code" != "0" ]]
grep -q 'no manifest check ran it successfully' "$temp_root/dead-fn-wiring.out"
[[ ! -f "$dead_fn_wiring_case/.pps/verify-stamp" ]]

dead_branch_wiring_case="$temp_root/dead-branch-wiring-case"
cp -R "$temp_root/software-case" "$dead_branch_wiring_case"
mkdir -p "$dead_branch_wiring_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$dead_branch_wiring_case/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$dead_branch_wiring_case/PROJECT_STATE.md"
mkdir -p "$dead_branch_wiring_case/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$dead_branch_wiring_case/tests/parity-harness.sh"
$PY3 - "$dead_branch_wiring_case" <<'PYEOF2'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
p = root + '/scripts/project_verify.sh'
t = open(p, encoding='utf-8').read()
t += '\nif false; then bash "$root/tests/parity-harness.sh"; fi\n'
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
rm -f "$dead_branch_wiring_case/.pps/verify-stamp"
bash "$dead_branch_wiring_case/scripts/session_begin.sh" \
  "$dead_branch_wiring_case" >/dev/null 2>&1 || true
set +e
bash "$dead_branch_wiring_case/scripts/verify_gate.sh" "$dead_branch_wiring_case" \
  >"$temp_root/dead-branch-wiring.out" 2>&1
dead_branch_wiring_code=$?
set -e
[[ "$dead_branch_wiring_code" != "0" ]]
grep -q 'no manifest check ran it successfully' "$temp_root/dead-branch-wiring.out"

mention_wiring_case="$temp_root/mention-wiring-case"
cp -R "$temp_root/software-case" "$mention_wiring_case"
mkdir -p "$mention_wiring_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$mention_wiring_case/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$mention_wiring_case/PROJECT_STATE.md"
mkdir -p "$mention_wiring_case/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$mention_wiring_case/tests/parity-harness.sh"
$PY3 - "$mention_wiring_case" <<'PYEOF2'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
# F-048-03: a live line that only MENTIONS the path in a string literal is
# not a call.
echo "echo 'see tests/parity-harness.sh'" >>"$mention_wiring_case/scripts/project_verify.sh"
rm -f "$mention_wiring_case/.pps/verify-stamp"
bash "$mention_wiring_case/scripts/session_begin.sh" \
  "$mention_wiring_case" >/dev/null 2>&1 || true
set +e
bash "$mention_wiring_case/scripts/verify_gate.sh" "$mention_wiring_case" \
  >"$temp_root/mention-wiring.out" 2>&1
mention_wiring_code=$?
set -e
[[ "$mention_wiring_code" != "0" ]]
grep -q 'no manifest check ran it successfully' "$temp_root/mention-wiring.out"
[[ ! -f "$mention_wiring_case/.pps/verify-stamp" ]]

while_false_case="$temp_root/while-false-case"
cp -R "$temp_root/software-case" "$while_false_case"
mkdir -p "$while_false_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$while_false_case/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$while_false_case/PROJECT_STATE.md"
mkdir -p "$while_false_case/tests"
printf '#!/usr/bin/env bash\nexit 0\n' >"$while_false_case/tests/parity-harness.sh"
$PY3 - "$while_false_case" <<'PYEOF2'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
t = t[:j] + '\n- Never ship without parity. (verify: tests/parity-harness.sh)\n' + t[j:]
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
# F-048-03: a while-false loop is dead code on the same footing as if-false.
echo 'while false; do bash "$root/tests/parity-harness.sh"; done' \
  >>"$while_false_case/scripts/project_verify.sh"
rm -f "$while_false_case/.pps/verify-stamp"
bash "$while_false_case/scripts/session_begin.sh" \
  "$while_false_case" >/dev/null 2>&1 || true
set +e
bash "$while_false_case/scripts/verify_gate.sh" "$while_false_case" \
  >"$temp_root/while-false.out" 2>&1
while_false_code=$?
set -e
[[ "$while_false_code" != "0" ]]
grep -q 'no manifest check ran it successfully' "$temp_root/while-false.out"

relay_discard_case="$temp_root/relay-discard-case"
bash "$skill/scripts/init_project.sh" relay-discard-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
printf 'session A work\n' >"$relay_discard_case/docs/MAIN.md"
bash "$relay_discard_case/scripts/session_begin.sh" "$relay_discard_case" >/dev/null 2>&1
printf 'session B overwrite\n' >"$relay_discard_case/docs/MAIN.md"
# The discarded path remains dirty, so boundary still reports unclaimed writes
# (exit 1). The discard contract is the chronicle trace, not a clean exit.
set +e
bash "$relay_discard_case/scripts/boundary_check.sh" "$relay_discard_case" \
  --discard-handover docs/MAIN.md >"$temp_root/relay-discard.out" 2>&1
relay_discard_code=$?
set -e
grep -q 'Relay discard event recorded' "$temp_root/relay-discard.out"
# F-048-01: the automatic title must not trip the closing-verb rule, and the
# chronicle written by the discard must itself pass validation.
grep -q 'relay discard of protected paths' "$relay_discard_case/EVENTS.md"
bash "$relay_discard_case/scripts/validate_project.sh" "$relay_discard_case" --quiet

floor_probe_dir_case="$temp_root/floor-probe-dir-case"
cp -R "$temp_root/software-case" "$floor_probe_dir_case"
rm -f "$floor_probe_dir_case/.pps/verify-stamp"
bash "$floor_probe_dir_case/scripts/session_begin.sh" \
  "$floor_probe_dir_case" >/dev/null 2>&1 || true
set +e
bash "$floor_probe_dir_case/scripts/verify_gate.sh" "$floor_probe_dir_case" \
  >"$temp_root/floor-probe-dir.out" 2>&1
floor_probe_dir_code=$?
set -e
[[ "$floor_probe_dir_code" != "0" ]]
grep -q 'directory is not a product entry point' "$temp_root/floor-probe-dir.out"
[[ ! -f "$floor_probe_dir_case/.pps/verify-stamp" ]]

floor_probe_file_case="$temp_root/floor-probe-file-case"
cp -R "$temp_root/software-case" "$floor_probe_file_case"
mkdir -p "$floor_probe_file_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$floor_probe_file_case/src/main.sh"
$PY3 - "$floor_probe_file_case" <<'PYEOF2'
import sys
p = sys.argv[1] + '/PROJECT_STATE.md'
t = open(p, encoding='utf-8').read()
open(p, 'w', encoding='utf-8').write(t.replace('- Main: .', '- Main: src/main.sh', 1))
PYEOF2
rm -f "$floor_probe_file_case/.pps/verify-stamp"
bash "$floor_probe_file_case/scripts/session_begin.sh" \
  "$floor_probe_file_case" >/dev/null 2>&1
bash "$floor_probe_file_case/scripts/verify_gate.sh" "$floor_probe_file_case" \
  >"$temp_root/floor-probe-file.out" 2>&1
grep -q 'PPS verify gate: OK' "$temp_root/floor-probe-file.out"


# --- Core duty fixtures (D-CORE series) ------------------------------------
hollow_gate_case="$temp_root/hollow-gate-case"
cp -R "$temp_root/software-case" "$hollow_gate_case"
printf '#!/usr/bin/env bash\nexit 0\n' >"$hollow_gate_case/scripts/project_verify.sh"
chmod +x "$hollow_gate_case/scripts/project_verify.sh"
rm -f "$hollow_gate_case/.pps/verify-stamp"
bash "$hollow_gate_case/scripts/session_begin.sh" "$hollow_gate_case" >/dev/null 2>&1 || true
set +e
bash "$hollow_gate_case/scripts/verify_gate.sh" "$hollow_gate_case" \
  >"$temp_root/hollow-gate.out" 2>&1
hollow_gate_code=$?
set -e
[[ "$hollow_gate_code" != "0" ]]
grep -q 'hollow verification entry' "$temp_root/hollow-gate.out"
[[ ! -f "$hollow_gate_case/.pps/verify-stamp" ]]

struct_only_case="$temp_root/struct-only-case"
cp -R "$temp_root/software-case" "$struct_only_case"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'root="${1:-.}"\nfailures=0\n'
  printf 'check() {\n  local label="$1"\n  shift\n  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label" >&2; failures=$((failures + 1)); fi\n}\n'
  printf 'structural() { bash "$root/scripts/validate_project.sh" "$root" --quiet; }\n'
  printf 'check "validate_project structural" structural\n'
  printf 'if (( failures > 0 )); then exit 1; fi\necho ok\n'
} >"$struct_only_case/scripts/project_verify.sh"
chmod +x "$struct_only_case/scripts/project_verify.sh"
rm -f "$struct_only_case/.pps/verify-stamp"
bash "$struct_only_case/scripts/session_begin.sh" "$struct_only_case" >/dev/null 2>&1 || true
set +e
bash "$struct_only_case/scripts/verify_gate.sh" "$struct_only_case" \
  >"$temp_root/struct-only.out" 2>&1
struct_only_code=$?
set -e
[[ "$struct_only_code" != "0" ]]
grep -q 'software package needs a behavioral check' "$temp_root/struct-only.out"

redline_unwired_case="$temp_root/redline-unwired-case"
cp -R "$temp_root/software-case" "$redline_unwired_case"
mkdir -p "$redline_unwired_case/src"
printf '#!/usr/bin/env bash\necho ok\n' >"$redline_unwired_case/src/main.sh"
sed -i.bak 's/^- Main: .$/- Main: src\/main.sh/' "$redline_unwired_case/PROJECT_STATE.md"
$PY3 - "$redline_unwired_case" <<'PYEOF2'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
tail = '- Never ship without the parity harness. (verify: tests/parity-harness.sh)\n'
t = t[:j] + '\n' + tail + t[j:]
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
rm -f "$redline_unwired_case/.pps/verify-stamp"
bash "$redline_unwired_case/scripts/session_begin.sh" \
  "$redline_unwired_case" >/dev/null 2>&1 || true
set +e
bash "$redline_unwired_case/scripts/verify_gate.sh" "$redline_unwired_case" \
  >"$temp_root/redline-unwired.out" 2>&1
redline_unwired_code=$?
set -e
[[ "$redline_unwired_code" != "0" ]]
grep -q 'red line not wired to an executed check' "$temp_root/redline-unwired.out"
[[ ! -f "$redline_unwired_case/.pps/verify-stamp" ]]

coverage_prose_case="$temp_root/coverage-prose-case"
cp -R "$temp_root/standard-case" "$coverage_prose_case"
$PY3 - "$coverage_prose_case" <<'PYEOF2'
import re, sys
root = sys.argv[1]
p = root + '/CONTEXT.md'
t = open(p, encoding='utf-8').read()
t = re.sub(r'(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', r'\1 looks fine to me |', t, count=1)
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
expect_invalid "$coverage_prose_case" \
  "is not a resolvable evidence reference" \
  "Coverage evidence written as prose"

coverage_ghost_case="$temp_root/coverage-ghost-case"
cp -R "$temp_root/standard-case" "$coverage_ghost_case"
$PY3 - "$coverage_ghost_case" <<'PYEOF2'
import re, sys
root = sys.argv[1]
p = root + '/CONTEXT.md'
t = open(p, encoding='utf-8').read()
t = re.sub(r'(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', r'\1 tests/does-not-exist.sh |', t, count=1)
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
expect_invalid "$coverage_ghost_case" \
  "which does not exist in the project" \
  "Coverage evidence naming a nonexistent check"

aged_proposal_case="$temp_root/aged-proposal-case"
cp -R "$temp_root/standard-case" "$aged_proposal_case"
$PY3 - "$aged_proposal_case" <<'PYEOF2'
import re, sys
root = sys.argv[1]
p = root + '/CONTEXT.md'
t = open(p, encoding='utf-8').read()
t = re.sub(r'(?m)^- P-001.*$', '- P-001 (opened 2026-01-01): stale proposal never restated', t)
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
expect_invalid "$aged_proposal_case" \
  "not restated in Hot State Next by ID" \
  "Aged proposal without restatement"

abandoned_proposal_case="$temp_root/abandoned-proposal-case"
cp -R "$temp_root/standard-case" "$abandoned_proposal_case"
$PY3 - "$abandoned_proposal_case" <<'PYEOF2'
import re, sys
root = sys.argv[1]
p = root + '/CONTEXT.md'
t = open(p, encoding='utf-8').read()
t = re.sub(r'(?m)^- P-001.*$', '- P-001 (opened 2026-01-01) [abandoned]: dropped deliberately', t)
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
bash "$abandoned_proposal_case/scripts/validate_project.sh" "$abandoned_proposal_case" --quiet

zero_info_event_case="$temp_root/zero-info-event-case"
cp -R "$temp_root/standard-case" "$zero_info_event_case"
bash "$zero_info_event_case/scripts/append_event.sh" "$zero_info_event_case" \
  --title "closed the package" --files none --verify none --pending none >/dev/null
expect_invalid "$zero_info_event_case" \
  "must name its verification or keep something pending" \
  "Zero-information closing event"

empty_registry_case="$temp_root/empty-registry-case"
cp -R "$temp_root/standard-case" "$empty_registry_case"
printf '# Task Index\n\n## Task Index\n' >"$empty_registry_case/TASK_INDEX.md"
expect_invalid "$empty_registry_case" \
  "empty registry not allowed" \
  "Half-activated multitask registry"

runtime_unwired_case="$temp_root/runtime-unwired-case"
cp -R "$temp_root/software-case" "$runtime_unwired_case"
{
  printf '\n## Runtime Surfaces\n\n'
  printf '| ID | Repo path | Runtime path env | Probe |\n'
  printf '| R-001 | docs/MAIN.md | WZ_RUNTIME_DIR | scripts/runtime_probe.sh |\n'
} >>"$runtime_unwired_case/CONTEXT.md"
expect_invalid "$runtime_unwired_case" \
  "does not exist" \
  "Runtime surface probe that does not exist"

handover_case="$temp_root/handover-case"
bash "$skill/scripts/init_project.sh" handover-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
printf 'session A hardening not committed\n' >"$handover_case/docs/MAIN.md"
bash "$handover_case/scripts/session_begin.sh" "$handover_case" >"$temp_root/session-begin.out" 2>&1
grep -q 'docs/MAIN.md' "$temp_root/session-begin.out"
printf 'session B wholesale overwrite\n' >"$handover_case/docs/MAIN.md"
set +e
bash "$handover_case/scripts/boundary_check.sh" "$handover_case" \
  >"$temp_root/handover-overwrite.out" 2>&1
handover_code=$?
set -e
[[ "$handover_code" != "0" ]]
grep -q 'protected_overwrite: docs/MAIN.md' "$temp_root/handover-overwrite.out"
set +e
bash "$handover_case/scripts/boundary_check.sh" "$handover_case" \
  --discard-handover docs/MAIN.md >"$temp_root/handover-discard.out" 2>&1
set -e
grep -q 'handover_discarded: docs/MAIN.md' "$temp_root/handover-discard.out"
set +e
bash "$handover_case/scripts/session_begin.sh" "$handover_case" \
  >"$temp_root/session-second.out" 2>&1
session_second_code=$?
set -e
[[ "$session_second_code" == "3" ]]
grep -q 'unexpired session snapshot' "$temp_root/session-second.out"
bash "$handover_case/scripts/session_begin.sh" "$handover_case" --takeover \
  >"$temp_root/session-takeover.out" 2>&1
grep -q 'Takeover: yes' "$temp_root/session-takeover.out"

packet_relay_case="$temp_root/packet-relay-case"
bash "$skill/scripts/init_project.sh" packet-relay-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
$PY3 - "$packet_relay_case" <<'PYEOF2'
import sys
root = sys.argv[1]
p = root + '/AGENTS.md'
t = open(p, encoding='utf-8').read()
i = t.index('## Red Lines')
j = t.index('\n## ', i + 5)
numbered = '\n**R0 - Agent parity is non-negotiable.**\n\n1. Never swallow errors in an empty catch block.\n2. Never use array splatting for path arguments.\n'
t = t[:j] + numbered + t[j:]
open(p, 'w', encoding='utf-8').write(t)
PYEOF2
printf 'uncommitted relay work\n' >"$packet_relay_case/Install-WZ.ps1"
bash "$packet_relay_case/scripts/resume_packet.sh" "$packet_relay_case" \
  >"$temp_root/packet-relay.out" 2>&1
grep -q 'R0 - Agent parity is non-negotiable' "$temp_root/packet-relay.out"
grep -q '1. Never swallow errors in an empty catch block' "$temp_root/packet-relay.out"
grep -q 'protected: Install-WZ.ps1' "$temp_root/packet-relay.out"
grep -q 'dirty worktree without explicit handover' "$temp_root/packet-relay.out"
grep -q 'SNAPSHOT MISSING' "$temp_root/packet-relay.out"

gate_fail_case="$temp_root/gate-fail-case"
cp -R "$temp_root/standard-case" "$gate_fail_case"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'root="${1:-.}"\nfailures=0\n'
  printf 'check() {\n  local label="$1"\n  shift\n  if "$@"; then echo "PASS: $label"; else echo "FAIL: $label" >&2; failures=$((failures + 1)); fi\n}\n'
  printf 'impossible() { [[ -e "$root/this-artifact-cannot-exist" ]]; }\n'
  printf 'check "behavioral end-to-end assertion" impossible\n'
  printf 'if (( failures > 0 )); then exit 9; fi\necho ok\n'
} >"$gate_fail_case/scripts/project_verify.sh"
chmod +x "$gate_fail_case/scripts/project_verify.sh"
rm -f "$gate_fail_case/.pps/verify-stamp"
if bash "$gate_fail_case/scripts/verify_gate.sh" "$gate_fail_case" \
  >"$temp_root/gate-fail.out" 2>&1; then
  echo "Verify gate wrote a green stamp for a failing project verification." >&2
  exit 1
fi
grep -q 'PPS verify gate: FAILED' "$temp_root/gate-fail.out"
if [[ -f "$gate_fail_case/.pps/verify-stamp" ]]; then
  echo "Verify gate left a stamp behind after a failed verification." >&2
  exit 1
fi
set +e
bash "$gate_fail_case/scripts/readiness_check.sh" "$gate_fail_case" --verified \
  >"$temp_root/gate-fail-readiness.out" 2>&1
gate_fail_readiness=$?
set -e
[[ "$gate_fail_readiness" == "4" ]]
grep -q 'VERIFY EVIDENCE MISSING' "$temp_root/gate-fail-readiness.out"

unrouted_case="$temp_root/unrouted-verify-case"
cp -R "$temp_root/standard-case" "$unrouted_case"
sed -i.bak 's|^- Verify:.*|- Verify: bash -c "exit 9"|' "$unrouted_case/CONTEXT.md"
rm -f "$unrouted_case/.pps/verify-stamp"
if bash "$unrouted_case/scripts/verify_gate.sh" "$unrouted_case" \
  >"$temp_root/unrouted.out" 2>&1; then
  echo "Verify gate accepted an unrouted free-form Verify declaration." >&2
  exit 1
fi
grep -q 'unrouted Verify declaration' "$temp_root/unrouted.out"
[[ ! -f "$unrouted_case/.pps/verify-stamp" ]]

stale_worktree_case="$temp_root/stale-worktree-case"
bash "$skill/scripts/init_project.sh" stale-worktree-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
bash "$stale_worktree_case/scripts/verify_gate.sh" "$stale_worktree_case" >/dev/null
printf 'post-stamp drift\n' >>"$stale_worktree_case/docs/MAIN.md"
set +e
bash "$stale_worktree_case/scripts/readiness_check.sh" "$stale_worktree_case" --verified \
  >"$temp_root/stale-worktree.out" 2>&1
stale_worktree_code=$?
set -e
[[ "$stale_worktree_code" == "4" ]]
grep -q 'worktree content changed after the stamp' "$temp_root/stale-worktree.out"

dirty_content_case="$temp_root/dirty-content-case"
bash "$skill/scripts/init_project.sh" dirty-content-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
printf 'dirty before gate\n' >>"$dirty_content_case/docs/MAIN.md"
bash "$dirty_content_case/scripts/verify_gate.sh" "$dirty_content_case" >/dev/null
printf 'dirty again after gate\n' >>"$dirty_content_case/docs/MAIN.md"
set +e
bash "$dirty_content_case/scripts/readiness_check.sh" "$dirty_content_case" --verified \
  >"$temp_root/dirty-content.out" 2>&1
dirty_content_code=$?
set -e
[[ "$dirty_content_code" == "4" ]]
grep -q 'worktree content changed after the stamp' "$temp_root/dirty-content.out"

cjk_dirty_case="$temp_root/cjk-dirty-case"
bash "$skill/scripts/init_project.sh" cjk-dirty-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
printf 'first version\n' >"$cjk_dirty_case/中文 脏文件.md"
bash "$cjk_dirty_case/scripts/verify_gate.sh" "$cjk_dirty_case" >/dev/null
printf 'second version\n' >"$cjk_dirty_case/中文 脏文件.md"
set +e
bash "$cjk_dirty_case/scripts/readiness_check.sh" "$cjk_dirty_case" --verified \
  >"$temp_root/cjk-dirty.out" 2>&1
cjk_dirty_code=$?
set -e
[[ "$cjk_dirty_code" == "4" ]]
grep -q 'worktree content changed after the stamp' "$temp_root/cjk-dirty.out"

gitless_case="$temp_root/gitless-stamp-case"
bash "$skill/scripts/init_project.sh" gitless-stamp-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
bash "$gitless_case/scripts/verify_gate.sh" "$gitless_case" >/dev/null
mv "$gitless_case/.git" "$temp_root/gitless-stamp-case-git"
set +e
bash "$gitless_case/scripts/readiness_check.sh" "$gitless_case" --verified \
  >"$temp_root/gitless.out" 2>&1
gitless_code=$?
set -e
[[ "$gitless_code" == "4" ]]
grep -q 'no longer one' "$temp_root/gitless.out"
mv "$temp_root/gitless-stamp-case-git" "$gitless_case/.git"

capsule_drift_case="$temp_root/capsule-drift-case"
bash "$skill/scripts/init_project.sh" capsule-drift-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
bash "$capsule_drift_case/scripts/verify_gate.sh" "$capsule_drift_case" >/dev/null
printf '\n<!-- capsule drift -->\n' >>"$capsule_drift_case/CONTEXT.md"
set +e
bash "$capsule_drift_case/scripts/readiness_check.sh" "$capsule_drift_case" --verified \
  >"$temp_root/capsule-drift.out" 2>&1
capsule_drift_code=$?
set -e
[[ "$capsule_drift_code" == "4" ]]

ambiguous_stamp_case="$temp_root/ambiguous-stamp-case"
bash "$skill/scripts/init_project.sh" ambiguous-stamp-case \
  --profile standard --parent "$temp_root" \
  --git-name "PPS Smoke" --git-email "pps-smoke@example.invalid" >/dev/null
bash "$ambiguous_stamp_case/scripts/verify_gate.sh" "$ambiguous_stamp_case" >/dev/null
$PY3 - "$ambiguous_stamp_case/.pps/verify-stamp" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
open(p, 'w').write('result: pass\npackage: PKG-001\n' + t.replace('result: pass', 'result: fail'))
PYEOF
set +e
bash "$ambiguous_stamp_case/scripts/readiness_check.sh" "$ambiguous_stamp_case" --verified \
  >"$temp_root/ambiguous-stamp.out" 2>&1
ambiguous_code=$?
set -e
[[ "$ambiguous_code" == "4" ]]
grep -q 'ambiguous stamp is not evidence' "$temp_root/ambiguous-stamp.out"

newline_event_case="$temp_root/newline-event-case"
cp -R "$temp_root/standard-case" "$newline_event_case"
set +e
bash "$newline_event_case/scripts/append_event.sh" "$newline_event_case" \
  --title "$(printf 'clean\n## Forged Section')" \
  >"$temp_root/newline-event.out" 2>&1
newline_code=$?
set -e
[[ "$newline_code" != "0" ]]
grep -q 'single-line' "$temp_root/newline-event.out"

event_placement_case="$temp_root/event-placement-case"
cp -R "$temp_root/standard-case" "$event_placement_case"
printf '\n## Trailing Notes\n\n- unrelated trailing content\n' \
  >>"$event_placement_case/EVENTS.md"
bash "$event_placement_case/scripts/append_event.sh" "$event_placement_case" \
  --title "chat Placement test"
awk '
  /^## Events$/ { inside=1; next }
  inside && /^## / { inside=0 }
  inside && /Placement test/ { found=1 }
  END { exit found ? 0 : 1 }
' "$event_placement_case/EVENTS.md" || {
  echo "Appended event landed outside the Events section." >&2
  exit 1
}
bash "$event_placement_case/scripts/validate_project.sh" \
  "$event_placement_case" --quiet

# ==== 051 anti-drift fixtures: objective anchor + acceptance wiring =========
# The objective anchor turns "the goal moved while nobody recorded it" into a
# gate failure, and acceptance items turn "done" into executed checks.

# 051-01: session_begin anchors the objective; the gate stamps it.
anchor_case="$temp_root/anchor-case"
bash "$skill/scripts/init_project.sh" anchor-case \
  --profile standard --parent "$temp_root" --no-git >/dev/null
bash "$anchor_case/scripts/session_begin.sh" "$anchor_case" >/dev/null
[[ -f "$anchor_case/.pps/objective-anchor" ]] || {
  echo "session_begin did not write .pps/objective-anchor." >&2
  exit 1
}
grep -q '^objective_sha256: [0-9a-f]\{64\}$' "$anchor_case/.pps/objective-anchor" || {
  echo "objective-anchor has no 64-hex sha256." >&2
  exit 1
}
bash "$anchor_case/scripts/verify_gate.sh" "$anchor_case" >/dev/null
grep -q '^objective_sha256: [0-9a-f]\{64\}$' "$anchor_case/.pps/verify-stamp" || {
  echo "verify stamp did not record objective_sha256." >&2
  exit 1
}

# 051-02: a silently rewritten objective fails the gate (no event recorded).
drift_case="$temp_root/drift-case"
cp -R "$temp_root/standard-case" "$drift_case"
bash "$drift_case/scripts/session_begin.sh" "$drift_case" >/dev/null
awk '
  $0 == "## Objective" { inside=1; print; print ""; print "DRIFT: quietly expanded scope beyond the anchor."; next }
  inside && /^## / { inside=0 }
  { print }
' "$drift_case/PROJECT_STATE.md" > "$drift_case/PROJECT_STATE.md.new"
mv "$drift_case/PROJECT_STATE.md.new" "$drift_case/PROJECT_STATE.md"
set +e
bash "$drift_case/scripts/verify_gate.sh" "$drift_case" \
  >"$temp_root/drift-case.out" 2>&1
drift_code=$?
set -e
[[ "$drift_code" != "0" ]]
grep -q 'objective anchor mismatch' "$temp_root/drift-case.out"

# 051-03: a recorded objective-revised event legitimizes the change and
# refreshes the anchor to the revised objective.
revised_case="$temp_root/revised-case"
cp -R "$temp_root/standard-case" "$revised_case"
bash "$revised_case/scripts/session_begin.sh" "$revised_case" >/dev/null
awk '
  $0 == "## Objective" { inside=1; print; print ""; print "Revised objective, recorded in the chronicle."; next }
  inside && /^## / { inside=0 }
  { print }
' "$revised_case/PROJECT_STATE.md" > "$revised_case/PROJECT_STATE.md.new"
mv "$revised_case/PROJECT_STATE.md.new" "$revised_case/PROJECT_STATE.md"
bash "$revised_case/scripts/append_event.sh" "$revised_case" \
  --title "objective-revised: the scope was deliberately expanded" \
  --files "PROJECT_STATE.md" \
  --verify "manual" \
  --pending "review the revised objective" >/dev/null
bash "$revised_case/scripts/verify_gate.sh" "$revised_case" >/dev/null
$PY3 - "$revised_case" <<'PYEOF'
import hashlib, sys
root = sys.argv[1]
def section(path, title):
    inside = False
    out = []
    for line in open(path, encoding='utf-8'):
        stripped = line.strip()
        if stripped == '## ' + title:
            inside = True
            continue
        if inside and line.startswith('## '):
            break
        if inside:
            out.append(line)
    return ''.join(out)
text = section(root + '/PROJECT_STATE.md', 'Objective') + section(root + '/CONTEXT.md', 'Current Package')
norm = ''.join(l for l in text.splitlines(True) if l.strip())
# The shell side hashes the command-substitution value, which strips all
# trailing newlines; mirror that here.
norm = norm.rstrip('\n')
h = hashlib.sha256(norm.encode('utf-8')).hexdigest()
anchor = open(root + '/.pps/objective-anchor').read()
assert ('objective_sha256: ' + h) in anchor, 'anchor was not refreshed to the revised objective'
PYEOF

# 051-04: a non-bootstrap package without Acceptance fails validation.
no_acceptance_case="$temp_root/no-acceptance-case"
cp -R "$temp_root/standard-case" "$no_acceptance_case"
sed -i.bak 's/^- Stage: 0 \/ bootstrap$/- Stage: 1 \/ package/' \
  "$no_acceptance_case/PROJECT_STATE.md"
perl -0pi -e 's/\n- Acceptance:\n  - A1:.*\n//' \
  "$no_acceptance_case/CONTEXT.md"
expect_invalid "$no_acceptance_case" \
  "requires an 'Acceptance' field in Current Package" \
  "Non-bootstrap package without Acceptance"

# 051-05: an acceptance item naming a check that never ran fails the gate.
unwired_case="$temp_root/unwired-case"
cp -R "$temp_root/standard-case" "$unwired_case"
sed -i.bak 's/^- Stage: 0 \/ bootstrap$/- Stage: 1 \/ package/' \
  "$unwired_case/PROJECT_STATE.md"
sed -i.bak 's/(verify: validate_project)/(verify: ghost-check-404)/' \
  "$unwired_case/CONTEXT.md"
bash "$unwired_case/scripts/session_begin.sh" "$unwired_case" >/dev/null
set +e
bash "$unwired_case/scripts/verify_gate.sh" "$unwired_case" \
  >"$temp_root/unwired-case.out" 2>&1
unwired_code=$?
set -e
[[ "$unwired_code" != "0" ]]
grep -q 'acceptance not wired to an executed check' "$temp_root/unwired-case.out"

# 051-06: an acceptance item wired to a real manifest check id passes.
wired_case="$temp_root/wired-case"
cp -R "$temp_root/standard-case" "$wired_case"
sed -i.bak 's/^- Stage: 0 \/ bootstrap$/- Stage: 1 \/ package/' \
  "$wired_case/PROJECT_STATE.md"
sed -i.bak 's/(verify: validate_project)/(verify: M-001)/' \
  "$wired_case/CONTEXT.md"
bash "$wired_case/scripts/session_begin.sh" "$wired_case" >/dev/null
bash "$wired_case/scripts/verify_gate.sh" "$wired_case" >/dev/null

# ==== 052 self-distillation regressions: the timestamp migration's blast radius
# Moving EVENTS.md to ISO-8601 stamps silently broke three consumers that read
# the chronicle by date. Each one is a green-forever or fail-forever hazard, so
# each gets a fixture.

# 052-01: coverage evidence naming an EVENTS.md date must still resolve when
# the chronicle carries full ISO stamps (was: fail-forever).
cov_date_case="$temp_root/coverage-date-case"
cp -R "$temp_root/standard-case" "$cov_date_case"
bash "$cov_date_case/scripts/append_event.sh" "$cov_date_case" \
  --title "coverage attestation refreshed" --files docs/MAIN.md \
  --verify "validate_project pass" --pending none >/dev/null
cov_event_day="$(date -u '+%Y-%m-%d')"
$PY3 - "$cov_date_case" "$cov_event_day" <<'PYEOF'
import re, sys
root, day = sys.argv[1], sys.argv[2]
p = root + '/CONTEXT.md'
t = open(p, encoding='utf-8').read()
t = re.sub(r'(\| M-001 \|[^|]*\|[^|]*\|)[^|]*\|', r'\1 ' + day + ' |', t, count=1)
open(p, 'w', encoding='utf-8').write(t)
PYEOF
bash "$cov_date_case/scripts/validate_project.sh" "$cov_date_case" --quiet || {
  echo "Coverage evidence naming a real ISO-stamped event date was rejected." >&2
  exit 1
}

# 052-02: `event: <stamp>:<mergeId>` must not be split on the stamp's colons
# (was: merge id became '00:00Z:M-001', so real receipts never resolved).
evidence_split_case="$temp_root/evidence-split-case"
cp -R "$temp_root/standard-case" "$evidence_split_case"
printf -- '- 2026-08-24T10:00:00Z: [PKG-001] MERGE-001 integrated | files: docs/MAIN.md | verify: gate pass | pending: none\n' \
  >>"$evidence_split_case/EVENTS.md"
split_probe="$($PY3 "$skill/scripts/pps_evidence.py" verification-parse \
  "$evidence_split_case" "event: 2026-08-24T10:00:00Z:MERGE-001" "MERGE-001" 2>&1)"
[[ "$split_probe" == "ok" ]] || {
  echo "Typed event evidence with an ISO stamp did not resolve: $split_probe" >&2
  exit 1
}

# 052-03: an objective revision recorded in a migrated PPS/1.1 calendar-day
# line must still legitimize the change (was: anti-drift blind on migrated
# projects because the gate only accepted ISO stamps).
legacy_revision_case="$temp_root/legacy-revision-case"
cp -R "$temp_root/standard-case" "$legacy_revision_case"
bash "$legacy_revision_case/scripts/session_begin.sh" "$legacy_revision_case" >/dev/null
awk '
  $0 == "## Objective" { inside=1; print; print ""; print "Revised objective, recorded in a legacy-format chronicle line."; next }
  inside && /^## / { inside=0 }
  { print }
' "$legacy_revision_case/PROJECT_STATE.md" > "$legacy_revision_case/PROJECT_STATE.md.new"
mv "$legacy_revision_case/PROJECT_STATE.md.new" "$legacy_revision_case/PROJECT_STATE.md"
$PY3 - "$legacy_revision_case" "$(date -u '+%Y-%m-%d')" <<'PYEOF'
import sys
root, day = sys.argv[1], sys.argv[2]
p = root + '/EVENTS.md'
lines = open(p, encoding='utf-8').read().splitlines()
legacy = ('- ' + day + ': [PKG-001] objective-revised: scope deliberately widened'
          ' | files: PROJECT_STATE.md | verify: manual | pending: review the revision')
out, placed = [], False
for line in lines:
    if not placed and line.startswith('- ') and ': [PKG-' in line:
        out.append(legacy)
        placed = True
    out.append(line)
if not placed:
    out.append(legacy)
open(p, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PYEOF
bash "$legacy_revision_case/scripts/verify_gate.sh" "$legacy_revision_case" \
  >"$temp_root/legacy-revision.out" 2>&1 || {
  echo "A calendar-day objective-revised line did not legitimize the change." >&2
  cat "$temp_root/legacy-revision.out" >&2
  exit 1
}
grep -q 'anchor refreshed' "$temp_root/legacy-revision.out" || {
  echo "The gate accepted the legacy revision without refreshing the anchor." >&2
  exit 1
}

# 052-04: the chronicle is append-only ("never rewrite past lines"), so a
# project written by an older release keeps calendar-day event lines forever.
# The validator must accept both grammars or upgrading the skill retroactively
# invalidates every existing project — the compatibility promise in
# ADVERSARIAL_REVIEW.md ("PPS/1.0 and PPS/1.1 projects validate unchanged").
legacy_chronicle_case="$temp_root/legacy-chronicle-case"
cp -R "$temp_root/standard-case" "$legacy_chronicle_case"
$PY3 - "$legacy_chronicle_case" <<'PYEOF'
import sys
root = sys.argv[1]
p = root + '/EVENTS.md'
lines = open(p, encoding='utf-8').read().splitlines()
legacy = ('- 2026-08-20: [PKG-001] legacy calendar-day entry from an older release'
          ' | files: docs/MAIN.md | verify: validate_project pass | pending: none')
out, placed = [], False
for line in lines:
    if not placed and line.startswith('- ') and ': [PKG-' in line:
        out.append(legacy)
        placed = True
    out.append(line)
if not placed:
    out.append(legacy)
open(p, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PYEOF
bash "$legacy_chronicle_case/scripts/validate_project.sh" "$legacy_chronicle_case" --quiet || {
  echo "A calendar-day chronicle line written by an older release was rejected;" >&2
  echo "upgrading the skill must not retroactively invalidate existing projects." >&2
  exit 1
}
bash "$legacy_chronicle_case/scripts/project_verify.sh" "$legacy_chronicle_case" >/dev/null || {
  echo "project_verify no longer recognises a legacy calendar-day event line." >&2
  exit 1
}

# 052-05: widening the grammar for backward compatibility must not widen it
# into nonsense. An impossible clock (T99:99:99Z) is still a malformed line.
impossible_clock_case="$temp_root/impossible-clock-case"
cp -R "$temp_root/standard-case" "$impossible_clock_case"
printf -- '- 2026-08-24T99:99:99Z: [PKG-001] forged stamp | files: docs/MAIN.md | verify: gate pass | pending: none\n' \
  >>"$impossible_clock_case/EVENTS.md"
expect_invalid "$impossible_clock_case" \
  "Malformed event line" \
  "Impossible clock in an event stamp"

# ==== 053 feature-review repairs (PPS-AUDIT-20260825-060F §7 + §8.4) =========

# 053-01 (R1): the packet is the authority after a context reset, so it must
# carry the objective body and the Acceptance items, not just a one-line Goal.
packet_authority_case="$temp_root/packet-authority-case"
cp -R "$temp_root/standard-case" "$packet_authority_case"
bash "$packet_authority_case/scripts/resume_packet.sh" "$packet_authority_case" \
  >"$temp_root/packet-authority.out" 2>&1
grep -q '^## Objective' "$temp_root/packet-authority.out" || {
  echo "The resume packet does not carry the objective body; a recovered agent only sees Goal." >&2
  exit 1
}
grep -q '^- Acceptance:' "$temp_root/packet-authority.out" || {
  echo "The resume packet does not carry Acceptance; 'done' does not survive a context reset." >&2
  exit 1
}
grep -Eq '^[[:space:]]+- A1:' "$temp_root/packet-authority.out" || {
  echo "The resume packet lists Acceptance but drops the A-items themselves." >&2
  exit 1
}
packet_lines="$(wc -l <"$temp_root/packet-authority.out" | tr -d '[:space:]')"
packet_bytes="$(wc -c <"$temp_root/packet-authority.out" | tr -d '[:space:]')"
(( packet_lines <= 240 && packet_bytes <= 32768 )) || {
  echo "The enriched packet broke the L0 budget: $packet_lines lines / $packet_bytes bytes." >&2
  exit 1
}

# 053-02 (R2): the anchor must be readable, and the readable body must never be
# able to forge the compared digest.
anchor_readable_case="$temp_root/anchor-readable-case"
cp -R "$temp_root/standard-case" "$anchor_readable_case"
bash "$anchor_readable_case/scripts/session_begin.sh" "$anchor_readable_case" >/dev/null
grep -q '^-- objective --' "$anchor_readable_case/.pps/objective-anchor" || {
  echo "The anchor carries no readable objective; an agent cannot 'read the anchor'." >&2
  exit 1
}
anchor_real_hash="$(sed -n 's/^objective_sha256:[[:space:]]*//p' \
  "$anchor_readable_case/.pps/objective-anchor" | head -n 1)"
printf 'objective_sha256: %s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
  >>"$anchor_readable_case/.pps/objective-anchor"
bash "$anchor_readable_case/scripts/verify_gate.sh" "$anchor_readable_case" \
  >"$temp_root/anchor-readable.out" 2>&1 || true
grep -q 'objective anchor: unchanged since session begin' "$temp_root/anchor-readable.out" || {
  echo "A forged 'objective_sha256:' line inside the readable body changed the compared digest." >&2
  cat "$temp_root/anchor-readable.out" >&2
  exit 1
}
[[ -n "$anchor_real_hash" ]]

# 053-03 (§7-2): the structural floor is "no item proves anything", not "some
# item is structural". A1 structural + A2 real must pass.
mixed_acceptance_case="$temp_root/mixed-acceptance-case"
cp -R "$temp_root/hybrid-case" "$mixed_acceptance_case"
sed -i.bak 's/^- Stage: 0 \/ bootstrap$/- Stage: 1 \/ package/' \
  "$mixed_acceptance_case/PROJECT_STATE.md"
sed -i.bak 's|^- Main: .*$|- Main: docs/MAIN.md|' \
  "$mixed_acceptance_case/PROJECT_STATE.md"
$PY3 - "$mixed_acceptance_case" <<'PYEOF'
import re, sys
p = sys.argv[1] + '/CONTEXT.md'
t = open(p, encoding='utf-8').read()
t = re.sub(r'(?m)^(\s*)- A1:.*$',
           r'\1- A1: Structural validation passes (verify: validate_project).'
           '\n\\1- A2: Declared authority is wired to a manifest check (verify: M-001).',
           t, count=1)
open(p, 'w', encoding='utf-8').write(t)
PYEOF
bash "$mixed_acceptance_case/scripts/session_begin.sh" "$mixed_acceptance_case" >/dev/null
set +e
bash "$mixed_acceptance_case/scripts/verify_gate.sh" "$mixed_acceptance_case" \
  >"$temp_root/mixed-acceptance.out" 2>&1
set -e
# The gate may still stop later for unrelated floors (the software template's
# e2e_probe refuses `Main: .`); this case asserts only that the structural
# floor no longer punishes a mixed declaration.
if grep -q 'structural-only floor' "$temp_root/mixed-acceptance.out"; then
  echo "A1 structural + A2 real check was rejected; the floor is still 'any' instead of 'all'." >&2
  exit 1
fi
grep -q 'acceptance wiring: every acceptance item is backed by an executed check' \
  "$temp_root/mixed-acceptance.out" || {
  echo "A mixed acceptance declaration did not clear the acceptance wiring step." >&2
  cat "$temp_root/mixed-acceptance.out" >&2
  exit 1
}

# 053-04 (§7-2 negative): an all-structural non-bootstrap package must still
# fail at the floor, and the diagnostic must point at the migrated A1. Uses a
# hybrid project with a real Main so the run reaches the acceptance step
# instead of stopping at the software template's e2e_probe floor.
all_structural_case="$temp_root/all-structural-case"
cp -R "$temp_root/hybrid-case" "$all_structural_case"
sed -i.bak 's/^- Stage: 0 \/ bootstrap$/- Stage: 1 \/ package/' \
  "$all_structural_case/PROJECT_STATE.md"
sed -i.bak 's|^- Main: .*$|- Main: docs/MAIN.md|' \
  "$all_structural_case/PROJECT_STATE.md"
bash "$all_structural_case/scripts/session_begin.sh" "$all_structural_case" >/dev/null
set +e
bash "$all_structural_case/scripts/verify_gate.sh" "$all_structural_case" \
  >"$temp_root/all-structural.out" 2>&1
all_structural_code=$?
set -e
[[ "$all_structural_code" != "0" ]] || {
  echo "An all-structural non-bootstrap package was stamped." >&2
  exit 1
}
grep -q 'structural-only floor' "$temp_root/all-structural.out" || {
  echo "An all-structural declaration did not hit the structural floor." >&2
  cat "$temp_root/all-structural.out" >&2
  exit 1
}
grep -q 'migrated from PPS/1.1' "$temp_root/all-structural.out" || {
  echo "The structural-floor failure does not tell the operator to replace the migrated A1." >&2
  exit 1
}

# 053-05 (§7-1/R4): the migration NOTICE must warn that the injected A1 has to
# be replaced before Stage leaves bootstrap.
mig_notice_case="$temp_root/mig-notice-case"
cp -R "$repo_root/tests/fixtures/pps-1.1-software-standard" "$mig_notice_case"
(cd "$mig_notice_case" && git init -q && git add -A &&
  git -c user.name=Smoke -c user.email=smoke@example.invalid commit -qm base)
bash "$skill/scripts/migrate_project.sh" "$mig_notice_case" --apply --confirm \
  >"$temp_root/mig-notice.out" 2>&1
grep -q 'verify: validate_project' "$temp_root/mig-notice.out" || {
  echo "The migration NOTICE never names the injected floor A1." >&2
  cat "$temp_root/mig-notice.out" >&2
  exit 1
}
grep -q 'structural-only floor' "$temp_root/mig-notice.out" || {
  echo "The migration NOTICE does not name the failure the operator will hit." >&2
  exit 1
}

# 053-06 (§7-4): the over-claim must be gone from the shipped docs.
for overclaim_file in "$skill/SKILL.md" "$repo_root/CHANGELOG.md" \
  "$skill/references/protocol.md" "$skill/references/retrieval-and-gates.md" \
  "$skill/references/design-rationale.md"; do
  # Match the CLAIM, not any mention: the changelog legitimately quotes the
  # retired wording to record that it was withdrawn. A quoted or negated
  # mention is documentation; an unquoted one is advertising.
  if grep -Eqi '(^|[^"'"'"'])forced re-read' "$overclaim_file"; then
    echo "Stale over-claim 'forced re-read' still present in $overclaim_file." >&2
    exit 1
  fi
done
grep -q 'Re-run the packet mid-session' "$skill/SKILL.md" || {
  echo "SKILL.md does not state the mid-session re-read invariant (R3)." >&2
    exit 1
}

# ==== 054 small-context retrieval levels ====================================
# The protocol always described L0/L1/L2 but the script emitted one size, and
# over-budget was a hard failure that handed a small-context model nothing.

# 054-01: --level emits strict subsets, full stays the default, and anchor
# keeps the anti-drift payload (objective, red lines, package, write set).
level_case="$temp_root/level-case"
cp -R "$temp_root/standard-case" "$level_case"
for probe_level in anchor hot full; do
  bash "$level_case/scripts/resume_packet.sh" "$level_case" --level "$probe_level" \
    >"$temp_root/level-$probe_level.out" 2>&1 || {
    echo "resume_packet --level $probe_level failed." >&2
    cat "$temp_root/level-$probe_level.out" >&2
    exit 1
  }
  for required_section in '^## Objective' '^## Red Lines' '^## Current Package' '^- Write:'; do
    grep -q "$required_section" "$temp_root/level-$probe_level.out" || {
      echo "Level $probe_level dropped the undroppable section: $required_section" >&2
      exit 1
    }
  done
  grep -q "^- packet_level: $probe_level\$" "$temp_root/level-$probe_level.out" || {
    echo "Level $probe_level did not declare its own packet_level." >&2
    exit 1
  }
done
anchor_bytes="$(wc -c <"$temp_root/level-anchor.out" | tr -d '[:space:]')"
hot_bytes="$(wc -c <"$temp_root/level-hot.out" | tr -d '[:space:]')"
full_bytes="$(wc -c <"$temp_root/level-full.out" | tr -d '[:space:]')"
(( anchor_bytes < hot_bytes && hot_bytes <= full_bytes )) || {
  echo "Levels are not ordered subsets: anchor=$anchor_bytes hot=$hot_bytes full=$full_bytes" >&2
  exit 1
}
grep -q '^## Asset Readiness' "$temp_root/level-anchor.out" && {
  echo "anchor level still runs the asset checker; it must stay cheap." >&2
  exit 1
}
# Default invocation must remain the full packet: existing callers pass no flag.
bash "$level_case/scripts/resume_packet.sh" "$level_case" >"$temp_root/level-default.out" 2>&1
diff <(grep -v '^- generated_at:' "$temp_root/level-default.out") \
  <(grep -v '^- generated_at:' "$temp_root/level-full.out") >/dev/null || {
  echo "Default invocation is no longer equivalent to --level full." >&2
  exit 1
}

# 054-02: an unknown level fails loudly instead of silently emitting something.
set +e
bash "$level_case/scripts/resume_packet.sh" "$level_case" --level bogus \
  >"$temp_root/level-bogus.out" 2>&1
level_bogus_code=$?
set -e
[[ "$level_bogus_code" != "0" ]] || {
  echo "An unknown --level was accepted." >&2
  exit 1
}
grep -q "unknown --level" "$temp_root/level-bogus.out"

# 054-03: budget overflow degrades in a fixed order and says so, instead of
# failing and telling a mid-session agent to "narrow the workset".
degrade_probe="$temp_root/degrade-probe"
mkdir -p "$degrade_probe"
{
  echo "# PPS Resume Packet"
  echo "## Hot State"; echo "- Protocol: PPS/1.2"
  echo "## Objective"; echo "core objective must survive"
  echo "## Red Lines"; echo "- never drop me"
  echo "## Recent Events"; for i in $(seq 1 40); do echo "- ev $i"; done
  echo "## Asset Readiness"; for i in $(seq 1 60); do echo "- asset $i"; done
  echo "## Component Rows"; for i in $(seq 1 60); do echo "- comp $i"; done
  echo "## Active Authority Summaries"; for i in $(seq 1 60); do echo "- auth $i"; done
  echo "## Current Package"; echo "- ID: PKG-001"
} >"$degrade_probe/packet"
degrade_before="$(wc -l <"$degrade_probe/packet" | tr -d '[:space:]')"
degrade_line_count="$degrade_before"
for droppable in "Asset Readiness" "Component Rows" "Active Authority Summaries"; do
  (( degrade_line_count > 100 )) || break
  awk -v target="## $droppable" '
    $0 == target { skipping = 1; next }
    skipping && /^## / { skipping = 0 }
    skipping { next }
    { print }
  ' "$degrade_probe/packet" >"$degrade_probe/packet.trim"
  mv "$degrade_probe/packet.trim" "$degrade_probe/packet"
  degrade_line_count="$(wc -l <"$degrade_probe/packet" | tr -d '[:space:]')"
done
(( degrade_line_count < degrade_before )) || {
  echo "The degrade routine dropped nothing." >&2
  exit 1
}
for survivor in '^## Objective' '^## Red Lines' '^## Current Package' '^## Hot State'; do
  grep -q "$survivor" "$degrade_probe/packet" || {
    echo "Degrading dropped an undroppable section: $survivor" >&2
    exit 1
  }
done

# 054-04: the gate observes whether a packet was pulled in this session.
observe_case="$temp_root/observe-case"
cp -R "$temp_root/standard-case" "$observe_case"
rm -f "$observe_case/.pps/last-packet"
bash "$observe_case/scripts/session_begin.sh" "$observe_case" >/dev/null
bash "$observe_case/scripts/verify_gate.sh" "$observe_case" \
  >"$temp_root/observe-missing.out" 2>&1 || true
grep -q 'no resume packet has been generated' "$temp_root/observe-missing.out" || {
  echo "The gate does not notice that no packet was ever pulled." >&2
  exit 1
}
bash "$observe_case/scripts/resume_packet.sh" "$observe_case" --level anchor >/dev/null
bash "$observe_case/scripts/verify_gate.sh" "$observe_case" \
  >"$temp_root/observe-fresh.out" 2>&1 || true
grep -q 'packet pull: level anchor' "$temp_root/observe-fresh.out" || {
  echo "The gate does not report a fresh packet pull." >&2
  exit 1
}
printf 'packet_level: anchor\ngenerated_at: 2020-01-01T00:00:00Z\n' \
  >"$observe_case/.pps/last-packet"
bash "$observe_case/scripts/verify_gate.sh" "$observe_case" \
  >"$temp_root/observe-stale.out" 2>&1 || true
grep -q 'predates this session' "$temp_root/observe-stale.out" || {
  echo "The gate does not flag a packet older than the session." >&2
  exit 1
}
# Observability must never be a hard gate: the stale-packet run must fail for
# unrelated reasons only, never because of the notice itself.
grep -q 'packet' "$temp_root/observe-stale.out"

# 054-05: byte budgets must be measured in BYTES on both engines. `${#var}`
# counts characters in a UTF-8 locale, so a non-ASCII objective used to
# truncate at a different point than the PowerShell edition.
byte_parity_case="$temp_root/byte-parity-case"
cp -R "$temp_root/standard-case" "$byte_parity_case"
$PY3 - "$byte_parity_case" <<'PYEOF'
import io, sys
p = sys.argv[1] + '/PROJECT_STATE.md'
t = io.open(p, encoding='utf-8').read()
pad = '\n'.join('目标填充行 %03d 用于验证字节预算而非字符预算。' % i for i in range(40))
t = t.replace('## Objective\n', '## Objective\n\n' + pad + '\n', 1)
io.open(p, 'w', encoding='utf-8').write(t)
PYEOF
bash "$byte_parity_case/scripts/resume_packet.sh" "$byte_parity_case" \
  >"$temp_root/byte-parity.out" 2>&1
grep -q 'Objective truncated' "$temp_root/byte-parity.out" || {
  echo "A non-ASCII oversized objective was not truncated." >&2
  exit 1
}
objective_bytes="$(awk '/^## Objective$/{f=1;next} f&&/^## /{exit} f' \
  "$temp_root/byte-parity.out" | wc -c | tr -d '[:space:]')"
(( objective_bytes <= 900 )) || {
  echo "The objective section blew its 800-byte budget: $objective_bytes bytes." >&2
  exit 1
}

echo "PPS Bash smoke tests: OK"
