#!/usr/bin/env bash
set -uo pipefail

usage() {
  echo "Usage: asset_check.sh [ROOT] [--all] [--handoff] [--risk] [--quick] [--structure]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
root_seen=0
check_all=0
handoff=0
risk=0
structure_only=0
quick=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) check_all=1; shift ;;
    --handoff) handoff=1; shift ;;
    --risk) risk=1; shift ;;
    --quick) quick=1; shift ;;
    --structure) structure_only=1; shift ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      (( root_seen == 0 )) || {
        usage >&2
        exit 2
      }
      [[ -d "$1" ]] || {
        echo "ERROR: project root is not a directory: $1" >&2
        exit 1
      }
      root="$(cd "$1" && pwd -P)"
      root_seen=1
      shift
      ;;
  esac
done

if (( quick == 1 && handoff == 1 )); then
  echo "ERROR: --handoff requires full SHA-256 verification and cannot be combined with --quick." >&2
  exit 2
fi

manifest="$root/ASSETS.md"
context="$root/CONTEXT.md"
errors=()
warnings=()
rows_file="$(mktemp "${TMPDIR:-/tmp}/pps-assets.XXXXXX")"
trap 'rm -f "$rows_file"' EXIT

add_error() { errors+=("$1"); }
add_warning() { warnings+=("$1"); }

workset_assets="none"
if [[ -f "$context" ]]; then
  workset_assets="$(
    awk '
      /^## Workset Manifest[[:space:]]*$/ { inside=1; next }
      inside && /^## / { exit }
      inside && /^-[[:space:]]*Assets:[[:space:]]*/ {
        sub("^-+[[:space:]]*Assets:[[:space:]]*", "")
        print
        exit
      }
    ' "$context"
  )"
  workset_assets="${workset_assets:-none}"
fi

current_ids=""
if [[ "$workset_assets" != "none" ]]; then
  if ! printf '%s\n' "$workset_assets" |
      grep -Eq '^A-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?([[:space:]]*,[[:space:]]*A-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)*$'; then
    add_error "Workset Assets must be 'none' or a strict comma-separated A-* list: $workset_assets"
  else
    current_ids="$(
      printf '%s\n' "$workset_assets" |
        tr ',' '\n' |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    )"
    duplicate_current="$(printf '%s\n' "$current_ids" | sort | uniq -d)"
    [[ -z "$duplicate_current" ]] ||
      add_error "Workset Assets contains duplicate IDs: $(printf '%s' "$duplicate_current" | tr '\n' ' ')"
  fi
fi

if [[ -f "$manifest" ]]; then
  awk -F'|' '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    /^\|[[:space:]]*A-/ {
      if (NF != 10) {
        print "MALFORMED\t" NR "\t" $0
        next
      }
      print trim($2) "\t" trim($3) "\t" trim($4) "\t" trim($5) "\t" \
        trim($6) "\t" trim($7) "\t" trim($8) "\t" trim($9)
    }
  ' "$manifest" >"$rows_file"
elif [[ -n "$current_ids" ]]; then
  add_error "Workset lists assets but ASSETS.md is missing."
fi

safe_relative_path() {
  local rel="$1"
  local current="$root"
  local segment
  local parts=()
  if [[ -z "$rel" || "$rel" == /* || "$rel" == *\\* ||
    "$rel" =~ ^[A-Za-z]:[\\/]|(^|/)\.\.(/|$) ]]; then
    return 1
  fi
  IFS='/' read -r -a parts <<< "$rel"
  for segment in "${parts[@]}"; do
    [[ -n "$segment" && "$segment" != "." ]] || continue
    current="$current/$segment"
    [[ ! -L "$current" ]] || return 1
  done
  return 0
}

row_ids=""
while IFS=$'\t' read -r id priority sync materialize locator sha bytes purpose; do
  [[ -n "$id" ]] || continue
  if [[ "$id" == "MALFORMED" ]]; then
    add_error "Malformed ASSETS.md row at line $priority: $sync"
    continue
  fi
  row_ids="${row_ids}${id}"$'\n'
  [[ "$id" =~ ^A-[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?$ ]] ||
    add_error "Malformed asset ID: $id"
  case "$priority" in
    core|supporting|reference) ;;
    *) add_error "Asset $id has unsupported Priority '$priority'." ;;
  esac
  case "$sync" in
    git|git-lfs|cloud|local-marker) ;;
    *) add_error "Asset $id has unsupported Sync '$sync'." ;;
  esac
  safe_relative_path "$materialize" ||
    add_error "Asset $id Materialize must be a safe project-relative path: $materialize"
  if [[ "$sync" == "cloud" || "$sync" == "local-marker" ]]; then
    [[ "$materialize" == local-assets/* ]] ||
      add_error "External asset $id must materialize under local-assets/: $materialize"
  fi
  [[ "$sha" =~ ^[0-9A-Fa-f]{64}$ ]] ||
    add_error "Asset $id SHA-256 must contain exactly 64 hexadecimal characters."
  [[ "$bytes" =~ ^[1-9][0-9]*$ ]] ||
    add_error "Asset $id Bytes must be a positive integer."
  [[ -n "$purpose" ]] || add_error "Asset $id Purpose cannot be empty."
  if [[ "$priority" == "core" && "$sync" == "local-marker" ]]; then
    add_error "Core asset $id cannot use local-marker; choose git, git-lfs, or cloud."
  fi
  if [[ "$sync" == "cloud" ]]; then
    cloud_spec="${locator#rclone:}"
    cloud_path="${cloud_spec#*:}"
    if [[ ! "$locator" =~ ^rclone:[A-Za-z0-9][A-Za-z0-9._-]*:[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
      [[ "$cloud_path" =~ (^|/)\.\.(/|$) ]]; then
      add_error "Cloud asset $id Locator must use restricted non-secret rclone:REMOTE:path syntax."
    fi
  fi
done <"$rows_file"
row_ids="$(printf '%s' "$row_ids" | sed '/^$/d')"

duplicate_rows="$(printf '%s\n' "$row_ids" | sed '/^$/d' | sort | uniq -d)"
while IFS= read -r id; do
  [[ -z "$id" ]] || add_error "ASSETS.md contains duplicate rows for $id."
done <<< "$duplicate_rows"

while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  count="$(printf '%s\n' "$row_ids" | grep -Fxc "$id" || true)"
  [[ "$count" == "1" ]] ||
    add_error "Workset asset $id must have exactly one ASSETS.md row, found $count."
  current_priority="$(
    awk -F'\t' -v wanted="$id" '$1 == wanted { print $2; exit }' "$rows_file"
  )"
  [[ "$current_priority" != "reference" ]] ||
    add_error "Reference asset $id cannot enter the current Workset; promote it to supporting or core."
done <<< "$current_ids"

if (( structure_only == 1 )); then
  if [[ ${#warnings[@]} -gt 0 ]]; then
    for message in "${warnings[@]}"; do echo "WARNING: $message"; done
  fi
  if [[ ${#errors[@]} -gt 0 ]]; then
    for message in "${errors[@]}"; do echo "ERROR: $message"; done
    exit 1
  fi
  echo "Asset registry structure: OK"
  exit 0
fi

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print tolower($1)}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | awk '{print tolower($NF)}'
  else
    return 1
  fi
}

selected_count=0
reference_count=0
while IFS=$'\t' read -r id priority sync materialize locator sha bytes purpose; do
  [[ -n "$id" && "$id" != "MALFORMED" ]] || continue
  selected=0
  current=0
  printf '%s\n' "$current_ids" | grep -Fxq "$id" && current=1
  if [[ "$priority" == "core" || "$current" == "1" || "$check_all" == "1" ]]; then
    selected=1
  fi
  if [[ "$priority" == "reference" ]]; then
    reference_count=$((reference_count + 1))
  fi
  (( selected == 1 )) || continue
  selected_count=$((selected_count + 1))
  path="$root/$materialize"
  if [[ ! -f "$path" ]]; then
    if [[ "$priority" == "reference" ]]; then
      add_warning "Reference asset $id is not materialized on this device: $materialize"
    else
      add_error "Required asset $id is not materialized on this device: $materialize"
    fi
    continue
  fi
  actual_bytes="$(wc -c < "$path" | tr -d ' ')"
  [[ "$actual_bytes" == "$bytes" ]] ||
    add_error "Asset $id size mismatch: expected $bytes bytes, found $actual_bytes."
  if (( quick == 0 )); then
    if ! actual_sha="$(sha256_file "$path")"; then
      add_error "No SHA-256 implementation is available to verify asset $id."
    elif [[ "$actual_sha" != "$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')" ]]; then
      add_error "Asset $id SHA-256 mismatch."
    fi
  fi
  if [[ "$sync" == "git" || "$sync" == "git-lfs" ]]; then
    if ! command -v git >/dev/null 2>&1 ||
      ! git -C "$root" ls-files --error-unmatch -- "$materialize" >/dev/null 2>&1; then
      add_error "Asset $id declares $sync but Materialize is not Git tracked: $materialize"
    elif [[ "$sync" == "git-lfs" ]]; then
      attr="$(git -C "$root" check-attr filter -- "$materialize" 2>/dev/null || true)"
      [[ "$attr" == *": lfs" ]] ||
        add_error "Asset $id declares git-lfs but Git attributes do not select LFS: $materialize"
    fi
  fi
  if (( handoff == 1 )) && [[ "$sync" == "cloud" ]]; then
    remote_spec="${locator#rclone:}"
    if ! command -v rclone >/dev/null 2>&1; then
      add_error "Cloud asset $id cannot prove its durable copy because rclone is unavailable."
    elif ! remote_json="$(
      rclone size "$remote_spec" --json --max-depth 1 2>/dev/null
    )"; then
      add_error "Cloud asset $id durable Locator is unreachable: $locator"
    else
      compact_json="$(printf '%s' "$remote_json" | tr -d '\r\n[:space:]')"
      remote_count="$(
        printf '%s\n' "$compact_json" |
          sed -n 's/.*"count":\([0-9][0-9]*\).*/\1/p'
      )"
      remote_bytes="$(
        printf '%s\n' "$compact_json" |
          sed -n 's/.*"bytes":\([0-9][0-9]*\).*/\1/p'
      )"
      if [[ "$remote_count" != "1" || "$remote_bytes" != "$bytes" ]]; then
        add_error "Cloud asset $id durable copy mismatch: expected 1 object / $bytes bytes, found ${remote_count:-unknown} object(s) / ${remote_bytes:-unknown} bytes."
      else
        echo "PASS cloud copy: $id [$locator]"
      fi
    fi
  fi
  if (( handoff == 1 )) && [[ "$sync" == "local-marker" ]] &&
    { [[ "$priority" == "core" ]] || (( current == 1 )); }; then
    add_error "Current asset $id is local-marker only; handoff would be materially incomplete."
  fi
  echo "PASS asset: $id [$priority/$sync] $materialize"
done <"$rows_file"

tracked_binary_bytes=0
tracked_binary_count=0
if (( risk == 1 )) && command -v git >/dev/null 2>&1 &&
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_file_list="$(mktemp "${TMPDIR:-/tmp}/pps-tracked.XXXXXX")"
  git -C "$root" ls-files >"$tracked_file_list"
  while IFS= read -r rel; do
    [[ -n "$rel" && -f "$root/$rel" ]] || continue
    lower="$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *.mp4|*.mov|*.mkv|*.avi|*.gif|*.png|*.jpg|*.jpeg|*.webp|*.wav|*.psd|*.ai|*.xlsx|*.xls|*.docx|*.pptx|*.pdf|*.zip|*.7z|*.rar) ;;
      *) continue ;;
    esac
    size="$(wc -c < "$root/$rel" | tr -d ' ')"
    attr="$(git -C "$root" check-attr filter -- "$rel" 2>/dev/null || true)"
    if [[ "$attr" == *": lfs" ]]; then
      continue
    fi
    tracked_binary_count=$((tracked_binary_count + 1))
    tracked_binary_bytes=$((tracked_binary_bytes + size))
    if (( size > 99614720 )); then
      add_error "Tracked non-LFS file exceeds the 95 MiB safe push ceiling: $rel ($size bytes)."
    elif (( size > 52428800 )); then
      add_warning "Tracked non-LFS file exceeds 50 MiB: $rel ($size bytes)."
    fi
  done <"$tracked_file_list"
  rm -f "$tracked_file_list"
  if (( tracked_binary_bytes > 104857600 )); then
    add_warning "Tracked non-LFS binary candidates total $tracked_binary_bytes bytes across $tracked_binary_count files; review LFS, cloud routing, and output retention."
  fi
fi

if [[ ${#warnings[@]} -gt 0 ]]; then
  for message in "${warnings[@]}"; do echo "WARNING: $message"; done
fi
if [[ ${#errors[@]} -gt 0 ]]; then
  echo "Asset readiness: FAILED (${#errors[@]} error(s))"
  for message in "${errors[@]}"; do echo "ERROR: $message"; done
  exit 1
fi
echo "Asset readiness: OK"
echo "Selected assets checked: $selected_count"
if (( quick == 1 )); then
  echo "Integrity level: existence-and-size (quick)"
else
  echo "Integrity level: SHA-256"
fi
echo "Reference markers: $reference_count"
if (( risk == 1 )); then
  echo "Tracked non-LFS binary candidates: $tracked_binary_count files / $tracked_binary_bytes bytes"
fi
