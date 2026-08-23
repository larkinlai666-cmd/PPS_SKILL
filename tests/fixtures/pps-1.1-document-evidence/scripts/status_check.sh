#!/usr/bin/env bash
set -uo pipefail

root="$(pwd)"
full=0
fetch=0
fetch_failed=0
asset_failed=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || {
        echo "Usage: status_check.sh [--root DIR] [--full] [--fetch]" >&2
        exit 2
      }
      root="$2"
      shift 2
      ;;
    --full)
      full=1
      shift
      ;;
    --fetch)
      fetch=1
      shift
      ;;
    *)
      echo "Usage: status_check.sh [--root DIR] [--full] [--fetch]" >&2
      exit 2
      ;;
  esac
done

state="$root/PROJECT_STATE.md"
if [[ ! -f "$state" ]]; then
  echo "PPS status: PROJECT_STATE.md not found in $root"
  exit 1
fi

hot_state="$(
  awk '
    $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" {inside=1; next}
    inside && /^##[[:space:]]/ {exit}
    inside {print}
  ' "$state"
)"

value() {
  printf '%s\n' "$hot_state" |
    sed -n "s/^-[[:space:]]*$1:[[:space:]]*//p"
}

for name in Protocol Profile Mode Stage Main Map Environment Package Status Capsule Coverage Blockers Next Updated Device; do
  current="$(value "$name")"
  [[ -n "$current" ]] || current="<missing>"
  echo "$name: $current"
done

if [[ -f "$root/CONTEXT.md" ]]; then
  echo "Context-Lines: $(wc -l < "$root/CONTEXT.md" | tr -d ' ')"
fi

if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Git-Branch: $(git -C "$root" branch --show-current)"
  remotes="$(git -C "$root" remote | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -n "$remotes" ]]; then
    echo "Git-Remotes: $remotes"
    if (( fetch == 1 )); then
      if git -C "$root" fetch --all --prune; then
        echo "Git-Fetch: OK"
      else
        echo "Git-Fetch: FAILED"
        fetch_failed=1
      fi
    fi
  else
    echo "Git-Remotes: none"
  fi
  echo "Git-Dirty: $(git -C "$root" status --porcelain | wc -l | tr -d ' ')"
  upstream="$(git -C "$root" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    ahead="$(git -C "$root" rev-list --count '@{upstream}..HEAD' 2>/dev/null || printf '0')"
    behind="$(git -C "$root" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || printf '0')"
    echo "Git-Upstream: $upstream"
    echo "Git-Ahead: $ahead"
    echo "Git-Behind: $behind"
  else
    echo "Git-Upstream: none"
  fi
  if (( full == 1 )); then
    git -C "$root" status --short
  fi
else
  echo "Git: not initialized"
fi

if (( full == 1 )) && [[ -f "$root/CONTEXT.md" ]]; then
  echo
  echo "=== CONTEXT.md ==="
  cat "$root/CONTEXT.md"
fi

if [[ -f "$root/scripts/asset_check.sh" ]]; then
  echo
  echo "=== Asset Readiness (quick) ==="
  bash "$root/scripts/asset_check.sh" "$root" --quick ||
    asset_failed=1
fi

validation_status=0
bash "$root/scripts/validate_project.sh" "$root" --quiet ||
  validation_status=$?
if (( validation_status != 0 || fetch_failed == 1 || asset_failed == 1 )); then
  exit 1
fi
exit 0
