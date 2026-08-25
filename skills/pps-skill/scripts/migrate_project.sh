#!/usr/bin/env bash
# PPS/1.0|1.1 -> 1.2 migration tool. Never guesses history into typed
# relations: pre-layer lineage uses lineage_incomplete with an explicit
# decision, and only --with-multitask opts a single-task project into the
# multitask layer.
#
#   migrate_project.sh [ROOT] --dry-run                    (default: plan)
#   migrate_project.sh [ROOT] --apply --confirm            (core upgrade)
#   migrate_project.sh [ROOT] --apply --confirm --with-multitask
#   migrate_project.sh [ROOT] --rollback DIR
#
# Core upgrade fills every PPS/1.2 requirement the old project lacks (gate
# scripts, Red Lines section, coverage evidence, proposal dates, active-block
# decision, EVENTS.md), then flips the protocol, runs the validator on both
# available engines and the verify gate on this platform, and automatically
# rolls back to the pre-apply file set if anything fails. A migrated project
# is therefore never left half-activated.
set -uo pipefail

root="$(pwd)"
mode="dry-run"
confirm=0
with_multitask=0
backup_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) mode="dry-run"; shift ;;
    --apply) mode="apply"; shift ;;
    --confirm) confirm=1; shift ;;
    --with-multitask) with_multitask=1; shift ;;
    --rollback) mode="rollback"; backup_dir="$2"; shift 2 ;;
    *) root="$1"; shift ;;
  esac
done
root="$(cd "$root" && pwd -P)"

die() { echo "migrate_project: $1" >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
skill_root="$(cd "$script_dir/.." && pwd -P)"
schema_src="$skill_root/references/state-machine.json"

protocol="$(awk '
  $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
  inside && /^##[[:space:]]/ { exit }
  inside && index($0, "- Protocol:") == 1 {
    sub("^- Protocol:[[:space:]]*", "")
    print
    exit
  }' "$root/PROJECT_STATE.md" 2>/dev/null)"

package_id="$(awk '
  $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
  inside && /^##[[:space:]]/ { exit }
  inside && index($0, "- Package:") == 1 {
    sub("^- Package:[[:space:]]*", "")
    print
    exit
  }' "$root/PROJECT_STATE.md" 2>/dev/null)"

# The protocol contract gates the upgrade modes; a rollback must stay
# available even when the project state is half-migrated.
if [[ "$mode" != "rollback" ]]; then
  [[ -n "$package_id" ]] || die "cannot resolve the current package from PROJECT_STATE.md"
  [[ -n "$protocol" ]] || die "cannot resolve the current protocol from PROJECT_STATE.md"
  case "$protocol" in
    PPS/1.0|PPS/1.1) ;;
    PPS/1.2) die "the project already declares PPS/1.2" ;;
    *) die "unsupported source protocol: $protocol" ;;
  esac
fi

today="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
decision_date="$(date -u '+%Y-%m-%d')"
file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Decision id avoidance: never collide with an id the project already uses.
used_ids="$(grep -Eo '^###[[:space:]]+D-[A-Za-z0-9-]+' "$root/DECISIONS.md" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
decision_id="D-MIGRATE-001"
n=1
while [[ " $used_ids " == *" $decision_id "* ]]; do
  n=$((n + 1))
  decision_id="D-MIGRATE-$(printf '%03d' "$n")"
done

decision_text() {
  cat <<EOF

### $decision_id [active]
- Date: $decision_date
- Decision: approve
- Subject: PPS/1.2 core migration
- Summary: Authorize upgrading this project from $protocol to PPS/1.2. Pre-layer history predates the typed layers; no historical merge is guessed into a relation.
EOF
}

event_text() {
  printf '%s\n' "- $today: [$package_id] migration_authorized $decision_id | files: scripts/, AGENTS.md, CONTEXT.md, DECISIONS.md, EVENTS.md, .pps/verify-manifest.txt | verify: validate_project pass | pending: review migrated coverage evidence"
}

dry_run() {
  echo "== PPS $protocol -> 1.2 migration plan (dry run) =="
  echo "project:  $root"
  echo "package:  $package_id"
  echo ""
  echo "Core upgrade (always):"
  echo " 1. Refresh scripts/ with the 1.2 gate, validator, and evidence engine"
  echo " 2. Ensure .pps/verify-manifest.txt exists"
  echo " 3. Ensure AGENTS.md opens with a Red Lines section"
  echo " 4. Upgrade bare 'Present' coverage cells to explicit evidence"
  echo " 5. Add '(opened DATE)' to proposals that lack it"
  echo " 6. Append $decision_id to DECISIONS.md AND the active authority block"
  echo " 7. Create EVENTS.md if missing and record migration_authorized"
  echo " 8. Flip Hot State 'Protocol:' to PPS/1.2"
  echo " 9. Run validate_project on both available engines, then the verify"
  echo "    gate on this platform; any failure rolls back automatically"
  if (( with_multitask == 1 )); then
    echo ""
    echo "Multitask opt-in (--with-multitask):"
    echo " A. Create TASK_INDEX.md with one integrator bootstrap task"
    echo " B. Create MERGES.md"
    echo " C. Add 'Writer: T-001' to Hot State"
  else
    echo ""
    echo "Multitask layer: NOT enabled. A single-task project stays single-task;"
    echo "run again with --with-multitask only when several long tasks coexist."
  fi
  echo ""
  echo "The upgrader does NOT guess historical merge relations and does NOT"
  echo "touch Main/Profile/Mode or project content."
}

apply() {
  [[ "$confirm" == "1" ]] || die "--apply requires --confirm"
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup="$root/.pps/migration-backup-$ts"
  mkdir -p "$backup"
  # Backup every project file except the migration state itself; record a
  # hash manifest so rollback can prove byte identity. The pre-existing .pps
  # file set is recorded separately so rollback can remove state the
  # migration's own session/gate runs created.
  (
    cd "$root"
    : > "$backup/files.sha256"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      mkdir -p "$backup/$(dirname "$rel")"
      cp "$rel" "$backup/$rel"
      printf '%s  %s\n' "$(file_sha "$rel")" "$rel" >> "$backup/files.sha256"
    done < <(find . -type f ! -path './.git/*' ! -path './.pps/*' | sed 's|^\./||' | sort)
    find .pps -type f ! -path '.pps/migration-backup-*' 2>/dev/null | sed 's|^\./||' | sort > "$backup/pps.preapply"
  )
  echo "migration backup: $backup"

  # ---- 1. Refresh the 1.2 scripts -----------------------------------------
  for script_name in \
    status_check.ps1 status_check.sh \
    validate_project.ps1 validate_project.sh \
    environment_doctor.ps1 environment_doctor.sh \
    resume_packet.ps1 resume_packet.sh \
    asset_check.ps1 asset_check.sh \
    readiness_check.ps1 readiness_check.sh \
    verify_gate.ps1 verify_gate.sh \
    project_verify.ps1 project_verify.sh \
    append_event.ps1 append_event.sh \
    boundary_check.ps1 boundary_check.sh \
    session_begin.ps1 session_begin.sh \
    migrate_project.ps1 migrate_project.sh \
    e2e_probe.ps1 e2e_probe.sh \
    pre-commit pre-commit.ps1; do
    [[ -f "$script_dir/$script_name" ]] && cp "$script_dir/$script_name" "$root/scripts/$script_name"
  done
  [[ -f "$script_dir/pps_evidence.py" ]] && cp "$script_dir/pps_evidence.py" "$root/scripts/pps_evidence.py"
  [[ -f "$schema_src" ]] && cp "$schema_src" "$root/scripts/state-machine.json"
  chmod +x "$root/scripts/pps_evidence.py" 2>/dev/null || true
  chmod +x "$root/scripts/"*.sh "$root/scripts/pre-commit" 2>/dev/null || true

  # ---- 2. Check manifest ---------------------------------------------------
  if [[ ! -f "$root/.pps/verify-manifest.txt" ]]; then
    mkdir -p "$root/.pps"
    printf '# PPS check manifest — check_id\tplatform\tcwd\ttimeout_s\texpected_exit\tcommand\tnote\nM-001\tpowershell\t.\t60\t0\t& ./scripts/project_verify.ps1 -Root .\tgate entry runs all project checks\nM-001\tbash\t.\t60\t0\tbash scripts/project_verify.sh .\tgate entry runs all project checks\n' > "$root/.pps/verify-manifest.txt"
  fi

  # ---- 2b. .gitignore: .pps holds device-local stamps and snapshots; a
  # 1.2 project must never commit them (and the relay lock must never see
  # them as dirty work).
  gitignore="$root/.gitignore"
  if [[ ! -f "$gitignore" ]]; then
    printf '# Local and generated files\n.pps/\nlocal-task-output/\n' > "$gitignore"
  else
    grep -q '^\.pps/' "$gitignore" || printf '\n.pps/\nlocal-task-output/\n' >> "$gitignore"
    grep -q '^local-task-output/' "$gitignore" || printf 'local-task-output/\n' >> "$gitignore"
  fi

  # ---- 3. Red Lines section ------------------------------------------------
  agents="$root/AGENTS.md"
  if [[ ! -f "$agents" ]]; then
    printf '# AGENTS.md\n\n## Red Lines\n\n- 暂无项目红线。第一次事故复盘后在此追加，勿删除本节。\n' > "$agents"
  elif ! grep -q '^##[[:space:]]*Red Lines[[:space:]]*$' "$agents"; then
    awk '
      NR == 1 && /^# / {
        print
        print ""
        print "## Red Lines"
        print ""
        print "- 暂无项目红线。第一次事故复盘后在此追加，勿删除本节。"
        print ""
        inserted = 1
        next
      }
      { print }
      END {
        if (!inserted) {
          print ""
          print "## Red Lines"
          print ""
          print "- 暂无项目红线。第一次事故复盘后在此追加，勿删除本节。"
        }
      }
    ' "$agents" > "$agents.new"
    mv "$agents.new" "$agents"
  fi

  # ---- 4/5. Coverage evidence + proposal dates -----------------------------
  coverage_file="$(awk '
    $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && index($0, "- Coverage:") == 1 {
      sub("^- Coverage:[[:space:]]*", "")
      print
      exit
    }' "$root/PROJECT_STATE.md")"
  context="$root/CONTEXT.md"
  upgraded_ids=""
  if [[ -n "$coverage_file" && -f "$root/$coverage_file" ]]; then
    bare_ids="$(awk -F'|' '
      $0 ~ /^\|/ && NF >= 4 {
        val = $(NF-1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
        if (val == "Present" || val == "present") {
          id = $2
          gsub(/[[:space:]]/, "", id)
          if (id ~ /^[MFD]-[A-Za-z0-9_-]+$/) print id
        }
      }' "$root/$coverage_file" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    upgraded_ids="$(printf '%s
' "$bare_ids" | tr ' ' '\n' | grep -Ev '^(M-001|M-002)$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    if [[ -n "$bare_ids" ]]; then
      awk -F'|' '
        BEGIN { OFS = FS }
        $0 ~ /^\|/ && NF >= 4 {
          val = $(NF-1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
          if (val == "Present" || val == "present") {
            id = $2
            gsub(/[[:space:]]/, "", id)
            if (id == "M-001") {
              $(NF-1) = " verify_gate: structural validation checks manifest IDs "
            } else if (id == "M-002") {
              $(NF-1) = " verify_gate: close requires gate pass and verify stamp "
            } else {
              $(NF-1) = " manual: migrated from '"$protocol"'; bind a real check "
            }
          }
          print
          next
        }
        { print }
      ' "$root/$coverage_file" > "$root/$coverage_file.new"
      mv "$root/$coverage_file.new" "$root/$coverage_file"
    fi
  fi
  # The migration decision now sits in the Workset Manifest Decisions, so it
  # needs one coverage row too; the gate-name evidence is a resolvable
  # reference (unlike the manual rows, it is enforced by the gate itself).
  if [[ -n "$coverage_file" && -f "$root/$coverage_file" ]] &&
    ! grep -Eq "^\|[[:space:]]*${decision_id}[[:space:]]*\|" "$root/$coverage_file"; then
    awk -v did="$decision_id" -v today="$today" '
      BEGIN { appended = 0 }
      $0 ~ /^##[[:space:]]+Constraint Coverage[[:space:]]*$/ { in_table = 1; print; next }
      in_table && /^\|/ { last_table_row = NR; print; next }
      in_table && $0 !~ /^[[:space:]]*$/ { in_table = 0; print; next }
      { print }
      END {
        if (!appended) {
          print "| " did " | Migration authorization | `DECISIONS.md` / Active Authority Index | verify_gate: structural validation checks manifest IDs |"
        }
      }
    ' "$root/$coverage_file" > "$root/$coverage_file.new"
    mv "$root/$coverage_file.new" "$root/$coverage_file"
  fi
  if [[ -f "$context" ]]; then
    # The 1.1 Verify declaration names prose validation; the 1.2 gate
    # refuses prose routing and requires the entry to route through
    # verify_gate/project_verify.
    if ! grep -q '^- Verify:.*verify_gate' "$context"; then
      awk '
        inside && index($0, "- Verify:") == 1 {
          print "- Verify: Run scripts/verify_gate.* (structural validation plus declared project checks); extend the gate with stack-specific checks after bootstrap."
          next
        }
        $0 ~ /^##[[:space:]]+Workset Manifest[[:space:]]*$/ { inside = 1 }
        $0 ~ /^##[[:space:]]/ && $0 !~ /^##[[:space:]]+Workset Manifest[[:space:]]*$/ { inside = 0 }
        { print }
      ' "$context" > "$context.new"
      mv "$context.new" "$context"
    fi
    awk -v date="$decision_date" '
      $0 ~ /^- P-[A-Za-z0-9_-]+:/ && $0 !~ /\(opened [0-9]{4}-[0-9]{2}-[0-9]{2}\)/ {
        sub(/: /, " (opened " date "): ")
      }
      { print }
    ' "$context" > "$context.new"
    mv "$context.new" "$context"
    # The 1.2 validator requires Current Package to declare what "done"
    # means. A migrated 1.1 capsule has a Goal but no acceptance items;
    # inject one bound to the gate itself so the migrated project validates
    # honestly instead of inheriting an anti-drift hole.
    if ! grep -Eq '^-[[:space:]]*Acceptance:' "$context"; then
      awk '
        $0 ~ /^##[[:space:]]+Current Package[[:space:]]*$/ { inside = 1; print; next }
        inside && /^##[[:space:]]/ { inside = 0 }
        inside && index($0, "- Goal:") == 1 && !added {
          print
          print "- Acceptance:"
          print "  - A1: Migrated package passes structural validation and the verify gate (verify: validate_project)."
          added = 1
          next
        }
        { print }
      ' "$context" > "$context.new"
      mv "$context.new" "$context"
    fi
  fi
  # Manual coverage evidence must stay openly pending: restate the upgraded
  # IDs in Hot State Next so the honest manual path validates.
  if [[ -n "$upgraded_ids" ]]; then
    awk -v ids="$upgraded_ids" '
      $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; print; next }
      inside && /^##[[:space:]]/ { inside=0 }
      inside && index($0, "- Next:") == 1 {
        print $0 " Coverage evidence review: " ids
        next
      }
      { print }
    ' "$root/PROJECT_STATE.md" > "$root/PROJECT_STATE.md.new"
    mv "$root/PROJECT_STATE.md.new" "$root/PROJECT_STATE.md"
  fi

  # ---- 6. Decision record + active block + event ---------------------------
  # The new active decision must also appear in the Workset Manifest, or
  # every migrated project carries the "active authority not in the workset"
  # warning forever.
  if [[ -f "$context" ]]; then
    awk -v did="$decision_id" '
      inside && index($0, "- Decisions:") == 1 {
        val = $0
        sub(/^- Decisions:[[:space:]]*/, "", val)
        if (val == "none") {
          print "- Decisions: " did
        } else {
          print $0 ", " did
        }
        next
      }
      $0 ~ /^##[[:space:]]+Workset Manifest[[:space:]]*$/ { inside = 1 }
      $0 ~ /^##[[:space:]]/ && $0 !~ /^##[[:space:]]+Workset Manifest[[:space:]]*$/ { inside = 0 }
      { print }
    ' "$context" > "$context.new"
    mv "$context.new" "$context"
  fi
  decisions="$root/DECISIONS.md"
  if [[ ! -f "$decisions" ]]; then
    printf '# Authority and Decisions\n\n## Active Authority Index\n\n<!-- PPS:ACTIVE:BEGIN -->\n<!-- PPS:ACTIVE:END -->\n\n## Authority Records\n\n## Status Events\n\n## Next ID Hints\n' > "$decisions"
  fi
  if ! grep -q '<!-- PPS:ACTIVE:BEGIN -->' "$decisions"; then
    awk '
      NR == 1 && /^# / {
        print
        print ""
        print "## Active Authority Index"
        print ""
        print "<!-- PPS:ACTIVE:BEGIN -->"
        print "<!-- PPS:ACTIVE:END -->"
        print ""
        inserted = 1
        next
      }
      { print }
      END {
        if (!inserted) {
          print ""
          print "## Active Authority Index"
          print ""
          print "<!-- PPS:ACTIVE:BEGIN -->"
          print "<!-- PPS:ACTIVE:END -->"
        }
      }
    ' "$decisions" > "$decisions.new"
    mv "$decisions.new" "$decisions"
  fi
  if ! grep -q "### $decision_id " "$decisions"; then
    decision_text >> "$decisions"
  fi
  if ! grep -q "\`$decision_id\`" "$decisions"; then
    perl -0pi -e "s/(<!-- PPS:ACTIVE:BEGIN -->\n)/\$1- \`$decision_id\`\n/" "$decisions"
  fi

  events="$root/EVENTS.md"
  if [[ ! -f "$events" ]]; then
    printf '# Events\n\n## Events\n\n' > "$events"
  fi
  if ! grep -Fq "[$package_id] migration_authorized" "$events"; then
    event_text >> "$events"
  fi

  # ---- 7. Multitask opt-in -------------------------------------------------
  if (( with_multitask == 1 )); then
    if [[ ! -f "$root/TASK_INDEX.md" ]]; then
      cat > "$root/TASK_INDEX.md" <<EOF
## Task Index

### T-001
- Title: Migration bootstrap integrator
- Role: integrator
- Status: active
- Active Package: $package_id
- Capsule: CONTEXT.md
- Output Root: none
- External Locator: none
EOF
    fi
    if [[ ! -f "$root/MERGES.md" ]]; then
      printf '# Merges\n\n## Merge Receipts\n\n<!-- No typed merge receipts yet. Pre-layer history predates this layer and is deliberately not guessed into relations. -->\n' > "$root/MERGES.md"
    fi
    if ! grep -q '^- Writer:' "$root/PROJECT_STATE.md"; then
      awk '
        $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; print; next }
        inside && /^##[[:space:]]/ { inside=0 }
        inside && index($0, "- Protocol:") == 1 { print $0; print "- Writer: T-001"; next }
        { print }
      ' "$root/PROJECT_STATE.md" > "$root/PROJECT_STATE.md.new"
      mv "$root/PROJECT_STATE.md.new" "$root/PROJECT_STATE.md"
    fi
  fi

  # ---- 8. Protocol flip (single atomic line rewrite) ------------------------
  sed -i.bak "s|^- Protocol: PPS/1.0$|- Protocol: PPS/1.2|; s|^- Protocol: PPS/1.1$|- Protocol: PPS/1.2|" "$root/PROJECT_STATE.md"
  rm -f "$root/PROJECT_STATE.md.bak"

  # ---- 9. Validation gate ---------------------------------------------------
  if ! bash "$root/scripts/validate_project.sh" "$root" >"$backup/validate-bash.log" 2>&1; then
    echo "migrate_project: PPS/1.2 validation FAILED on the migrated state:" >&2
    cat "$backup/validate-bash.log" >&2
    rollback "$backup"
    exit 1
  fi
  if command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
    local pwsh_bin="$(command -v pwsh || command -v powershell)"
    if ! "$pwsh_bin" -NoProfile -ExecutionPolicy Bypass \
      -File "$root/scripts/validate_project.ps1" -Root "$root" -Quiet \
      >"$backup/validate-ps.log" 2>&1; then
      echo "migrate_project: PPS/1.2 validation FAILED under PowerShell on the migrated state:" >&2
      cat "$backup/validate-ps.log" >&2
      rollback "$backup"
      exit 1
    fi
  fi
  if ! bash "$root/scripts/session_begin.sh" "$root" >"$backup/gate.log" 2>&1 ||
    ! bash "$root/scripts/verify_gate.sh" "$root" >>"$backup/gate.log" 2>&1; then
    echo "migrate_project: the PPS/1.2 verify gate FAILED on the migrated state:" >&2
    tail -n 30 "$backup/gate.log" >&2
    rollback "$backup"
    exit 1
  fi

  echo "migration applied and verified; backup: $backup"
  echo "protocol: PPS/1.2"
  if (( with_multitask == 1 )); then
    echo "multitask layer: enabled (TASK_INDEX.md, MERGES.md, Writer: T-001)"
  else
    echo "multitask layer: NOT enabled (single-task stays single-task; opt in with --with-multitask when needed)"
  fi
  echo "NOTICE: review the coverage rows marked 'manual: migrated from PPS/1.1' in Hot State Next, then bind real checks."
  echo "NOTICE: the migrated capsule carries a floor acceptance item 'A1: ... (verify: validate_project)'."
  echo "        It passes while Stage stays 'bootstrap'. Before you move Stage past bootstrap on a"
  echo "        software/hybrid project, replace that A1 with a manifest check id or a real artifact"
  echo "        path, otherwise the verify gate will fail with 'acceptance items are structural-only floor'."
}

rollback() {
  backup_dir="${1:-$backup_dir}"
  [[ -n "$backup_dir" && -d "$backup_dir" ]] || die "rollback needs a backup directory created by --apply"
  backup_dir="$(cd "$backup_dir" && pwd -P)"
  [[ -f "$backup_dir/files.sha256" ]] || die "backup $backup_dir has no hash manifest"
  # Restore the pre-apply file set exactly: files that existed come back,
  # files apply created (no backup entry) are deleted.
  (
    cd "$root"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      mkdir -p "$(dirname "$rel")"
      cp "$backup_dir/$rel" "$rel"
    done < <(cd "$backup_dir" && find . -type f ! -name 'files.sha256' ! -name 'validate-bash.log' ! -name 'validate-ps.log' ! -name 'gate.log' | sed 's|^\./||')
    find . -type f ! -path './.git/*' ! -path './.pps/*' | sed 's|^\./||' | sort > "$backup_dir/restored.files"
    (cd "$backup_dir" && find . -type f ! -name 'files.sha256' ! -name 'restored.files' ! -name 'preapply.files' ! -name 'pps.preapply' ! -name 'validate-bash.log' ! -name 'validate-ps.log' ! -name 'gate.log' | sed 's|^\./||' | sort) > "$backup_dir/preapply.files"
    # Delete files that did not exist before apply.
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      if ! grep -Fxq "$rel" "$backup_dir/preapply.files"; then
        rm -f "$root/$rel"
      fi
    done < "$backup_dir/restored.files"
  )
  # Byte-identity check: every restored file must match the pre-apply hash.
  mismatch=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    want="${line%%  *}"
    rel="${line#*  }"
    [[ -f "$root/$rel" ]] || { echo "migrate_project: rollback mismatch: $rel is missing" >&2; mismatch=1; continue; }
    got="$(file_sha "$root/$rel")"
    [[ "$got" == "$want" ]] || { echo "migrate_project: rollback mismatch: $rel hash differs" >&2; mismatch=1; }
  done < "$backup_dir/files.sha256"
  if (( mismatch == 1 )); then
    echo "migrate_project: rollback FAILED to restore byte identity; inspect $root against $backup_dir" >&2
    exit 1
  fi
  # Remove any leftover empty .pps state the migration itself created.
  if [[ -f "$backup_dir/pps.preapply" ]]; then
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      [[ -f "$root/$rel" ]] || continue
      case "$rel" in
        .pps/migration-backup-*) continue ;;
      esac
      if ! grep -Fxq "$rel" "$backup_dir/pps.preapply"; then
        rm -f "$root/$rel"
      fi
    done < <(cd "$root" && find .pps -type f 2>/dev/null | sed 's|^\./||')
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      rmdir "$root/$(dirname "$rel")" 2>/dev/null || true
    done < <(cd "$root" && find .pps -type d -empty 2>/dev/null | sed 's|^\./||')
  fi
  echo "migration rolled back from $backup_dir (file set and hashes verified)"
}

case "$mode" in
  dry-run) dry_run ;;
  apply) apply ;;
  rollback) rollback ;;
  *) die "unknown mode: $mode" ;;
esac
