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

bash "$skill/scripts/validate_skill.sh" "$skill"
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
sed -i.bak 's/^- Required: git$/- Required: python/' \
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
python3 - "$temp_root/receipt-status-mismatch" <<'PYEOF'
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
python3 - "$receipt_base" <<'PYEOF'
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
  "nor recorded as a real event line" \
  "Receipt targeting package only mentioned in a comment"

cp -R "$receipt_base" "$temp_root/receipt-rejected-approval"
write_receipt "$temp_root/receipt-rejected-approval" D-002 "validate_project pass" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-rejected-approval" \
  "a decision that never authorized the merge cannot approve it" \
  "Receipt citing a rejected decision as approval"

cp -R "$receipt_base" "$temp_root/receipt-prose-verification"
write_receipt "$temp_root/receipt-prose-verification" D-001 "looked fine to me" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-prose-verification" \
  "is not a resolvable evidence reference" \
  "Receipt with prose-only verification"

cp -R "$receipt_base" "$temp_root/receipt-ghost-accepted"
write_receipt "$temp_root/receipt-ghost-accepted" D-001 "validate_project pass" local-task-output/T-002/ghost.md PKG-001
expect_invalid "$temp_root/receipt-ghost-accepted" \
  "an integration must point at real merged artifacts" \
  "Receipt accepting a nonexistent artifact"

cp -R "$receipt_base" "$temp_root/receipt-missing-evidence-doc"
write_receipt "$temp_root/receipt-missing-evidence-doc" D-001 "docs/nonexistent-evidence.md" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-missing-evidence-doc" \
  "which does not exist" \
  "Receipt citing a nonexistent evidence document"

cp -R "$receipt_base" "$temp_root/receipt-bare-gate-name"
write_receipt "$temp_root/receipt-bare-gate-name" D-001 "verify_gate" local-task-output/T-002/real.md PKG-001
expect_invalid "$temp_root/receipt-bare-gate-name" \
  "names a gate without a recorded outcome" \
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
python3 - "$temp_root/receipt-lineage-no-migration" <<'PYEOF'
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
python3 - "$temp_root/archived-contradiction" <<'PYEOF'
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

# --- Core duty fixtures (D-CORE series) ------------------------------------
hollow_gate_case="$temp_root/hollow-gate-case"
cp -R "$temp_root/software-case" "$hollow_gate_case"
printf '#!/usr/bin/env bash\nexit 0\n' >"$hollow_gate_case/scripts/project_verify.sh"
chmod +x "$hollow_gate_case/scripts/project_verify.sh"
rm -f "$hollow_gate_case/.pps/verify-stamp"
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
set +e
bash "$struct_only_case/scripts/verify_gate.sh" "$struct_only_case" \
  >"$temp_root/struct-only.out" 2>&1
struct_only_code=$?
set -e
[[ "$struct_only_code" != "0" ]]
grep -q 'software package needs a behavioral check' "$temp_root/struct-only.out"

redline_unwired_case="$temp_root/redline-unwired-case"
cp -R "$temp_root/software-case" "$redline_unwired_case"
python3 - "$redline_unwired_case" <<'PYEOF2'
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
set +e
bash "$redline_unwired_case/scripts/verify_gate.sh" "$redline_unwired_case" \
  >"$temp_root/redline-unwired.out" 2>&1
redline_unwired_code=$?
set -e
[[ "$redline_unwired_code" != "0" ]]
grep -q 'red line not wired to the gate' "$temp_root/redline-unwired.out"
[[ ! -f "$redline_unwired_case/.pps/verify-stamp" ]]

coverage_prose_case="$temp_root/coverage-prose-case"
cp -R "$temp_root/standard-case" "$coverage_prose_case"
python3 - "$coverage_prose_case" <<'PYEOF2'
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
python3 - "$coverage_ghost_case" <<'PYEOF2'
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
python3 - "$aged_proposal_case" <<'PYEOF2'
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
python3 - "$abandoned_proposal_case" <<'PYEOF2'
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
python3 - "$packet_relay_case" <<'PYEOF2'
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
grep -q 'PPS verify gate: FAILED (project verification)' "$temp_root/gate-fail.out"
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
python3 - "$ambiguous_stamp_case/.pps/verify-stamp" <<'PYEOF'
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
  --title "note Placement test"
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

echo "PPS Bash smoke tests: OK"
