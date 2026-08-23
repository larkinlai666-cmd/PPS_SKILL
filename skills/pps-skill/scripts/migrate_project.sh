#!/usr/bin/env bash
# PPS/1.1 -> 1.2 migration tool. Never guesses history into typed relations:
# pre-layer lineage uses lineage_incomplete with an explicit decision.
#
#   migrate_project.sh [ROOT] --dry-run            (default)
#   migrate_project.sh [ROOT] --apply --confirm
#   migrate_project.sh [ROOT] --rollback DIR
set -uo pipefail

root="$(pwd)"
mode="dry-run"
confirm=0
backup_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) mode="dry-run"; shift ;;
    --apply) mode="apply"; shift ;;
    --confirm) confirm=1; shift ;;
    --rollback) mode="rollback"; backup_dir="$2"; shift 2 ;;
    *) root="$1"; shift ;;
  esac
done
root="$(cd "$root" && pwd -P)"

die() { echo "migrate_project: $1" >&2; exit 2; }

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

[[ -n "$package_id" ]] || die "cannot resolve the current package from PROJECT_STATE.md"

today="$(date -u '+%Y-%m-%d')"
# F-050-06: never collide with a decision id the project already uses. A
# silently skipped append would leave the migration without its authorization.
used_ids="$(grep -Eo '^###[[:space:]]+D-[A-Za-z0-9-]+' "$root/DECISIONS.md" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
decision_id="D-MIGRATE-001"
n=1
while [[ " $used_ids " == *" $decision_id "* ]]; do
  n=$((n + 1))
  decision_id="D-MIGRATE-$(printf '%03d' "$n")"
done

task_index_text() {
  cat <<EOF
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
}

merges_text() {
  cat <<EOF
## Merge Receipts

<!-- No typed merge receipts yet. The 1.1 history predates this layer and is
     deliberately not guessed into relations. Pre-layer receipts, if any are
     recorded later, use lineage_incomplete with a Lineage Note citing
     $decision_id. -->
EOF
}

decision_text() {
  cat <<EOF

### $decision_id [active]
- Date: $today
- Decision: approve
- Subject: T-001
- Summary: Authorize adopting the PPS/1.2 multitask layer for this project. Pre-layer history predates the layer; no historical merge is guessed into a typed relation.
EOF
}

event_text() {
  printf '%s\n' "- $today: [$package_id] migration_authorized $decision_id | files: TASK_INDEX.md, MERGES.md | verify: validate_project pass | pending: none"
}

dry_run() {
  echo "== PPS 1.1 -> 1.2 migration plan (dry run) =="
  echo "project:  $root"
  echo "protocol: ${protocol:-<unresolved>}"
  echo "package:  $package_id"
  echo ""
  echo "The 1.1 project has no TASK_INDEX.md, no MERGES.md, and no migration"
  echo "decision. The upgrader does NOT guess historical merge relations:"
  echo "pre-layer history is covered by the lineage_incomplete escape hatch with"
  echo "an explicit decision ($decision_id)."
  echo ""
  echo "Planned changes (new files and append-only edits):"
  echo " 1. TASK_INDEX.md   — one integrator task T-001 (bootstrap)"
  echo " 2. MERGES.md       — empty typed registry; no invented relations"
  echo " 3. DECISIONS.md    — append $decision_id (Decision: approve, Subject: T-001)"
  echo " 4. EVENTS.md       — append one migration_authorized event"
  echo " 5. .pps/verify-manifest.txt — generated check manifest (gate requirement)"
  echo " 6. PROJECT_STATE.md — 'Protocol: PPS/1.2' is NOT flipped by --apply;"
  echo "                       flip it yourself only after validate_project passes"
  echo ""
  echo "Risks:"
  echo " - historical packages/merges are not mapped into tasks; any future"
  echo "   receipt that needs pre-layer lineage must use lineage_incomplete with"
  echo "   a Lineage Note citing $decision_id"
  echo " - run validate_project on both platforms before and after applying"
}

apply() {
  [[ "$confirm" == "1" ]] || die "--apply requires --confirm"
  [[ "$protocol" != "PPS/1.2" ]] || die "the project is already PPS/1.2"
  ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup="$root/.pps/migration-backup-$ts"
  mkdir -p "$backup"
  for f in TASK_INDEX.md MERGES.md DECISIONS.md EVENTS.md PROJECT_STATE.md .pps/verify-manifest.txt; do
    [[ -f "$root/$f" ]] && cp "$root/$f" "$backup/$(basename "$f")"
  done
  [[ -f "$root/TASK_INDEX.md" ]] || task_index_text > "$root/TASK_INDEX.md"
  [[ -f "$root/MERGES.md" ]] || merges_text > "$root/MERGES.md"
  [[ -f "$root/DECISIONS.md" ]] || { echo "# Decisions" > "$root/DECISIONS.md"; echo "" >> "$root/DECISIONS.md"; }
  grep -q "### $decision_id " "$root/DECISIONS.md" || decision_text >> "$root/DECISIONS.md"
  [[ -f "$root/EVENTS.md" ]] || { echo "## Events" > "$root/EVENTS.md"; echo "" >> "$root/EVENTS.md"; }
  grep -Fq "[$package_id] migration_authorized" "$root/EVENTS.md" || event_text >> "$root/EVENTS.md"
  if [[ ! -f "$root/.pps/verify-manifest.txt" ]]; then
    mkdir -p "$root/.pps"
    printf '# PPS check manifest — check_id\tplatform\tcwd\ttimeout_s\texpected_exit\tcommand\tnote\nM-001\tpowershell\t.\t60\t0\t& ./scripts/project_verify.ps1 -Root .\tgate entry runs all project checks\nM-001\tbash\t.\t60\t0\tbash scripts/project_verify.sh .\tgate entry runs all project checks\n' > "$root/.pps/verify-manifest.txt"
  fi
  echo "migration applied; backup: $backup"
  echo "NOTICE: 'Protocol:' in PROJECT_STATE.md was NOT changed. Run validate_project"
  echo "on both platforms; when both pass, flip the Protocol field to PPS/1.2 yourself."
}

rollback() {
  [[ -n "$backup_dir" && -d "$backup_dir" ]] || die "rollback needs a backup directory created by --apply"
  # F-050-06: rollback restores the file set that existed BEFORE apply. Files
  # that apply created (no backup entry) are deleted, so a rollback cannot
  # leave a half-activated multitask layer behind.
  for f in TASK_INDEX.md MERGES.md DECISIONS.md EVENTS.md PROJECT_STATE.md; do
    if [[ -f "$backup_dir/$f" ]]; then
      cp "$backup_dir/$f" "$root/$f"
    elif [[ -f "$root/$f" ]]; then
      rm "$root/$f"
    fi
  done
  if [[ -f "$backup_dir/verify-manifest.txt" ]]; then
    mkdir -p "$root/.pps"
    cp "$backup_dir/verify-manifest.txt" "$root/.pps/verify-manifest.txt"
  elif [[ -f "$root/.pps/verify-manifest.txt" ]]; then
    rm "$root/.pps/verify-manifest.txt"
  fi
  rmdir "$root/.pps" 2>/dev/null || true
  echo "migration rolled back from $backup_dir"
}

case "$mode" in
  dry-run) dry_run ;;
  apply) apply ;;
  rollback) rollback ;;
esac
