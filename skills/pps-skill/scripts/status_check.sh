#!/usr/bin/env bash
set -u

root="$(pwd)"
full=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="$2"
      shift 2
      ;;
    --full)
      full=1
      shift
      ;;
    *)
      echo "Usage: status_check.sh [--root DIR] [--full]" >&2
      exit 2
      ;;
  esac
done

state="$root/PROJECT_STATE.md"
if [[ ! -f "$state" ]]; then
  echo "PPS status: PROJECT_STATE.md not found in $root"
  exit 1
fi

value() {
  sed -n "s/^-[[:space:]]*$1:[[:space:]]*//p" "$state"
}

for name in Protocol Profile Stage Main Package Status Blockers Next; do
  current="$(value "$name")"
  [[ -n "$current" ]] || current="<missing>"
  echo "$name: $current"
done

if [[ -f "$root/CONTEXT.md" ]]; then
  echo "Context-Lines: $(wc -l < "$root/CONTEXT.md" | tr -d ' ')"
fi

if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Git-Branch: $(git -C "$root" branch --show-current)"
  echo "Git-Dirty: $(git -C "$root" status --porcelain | wc -l | tr -d ' ')"
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

bash "$root/scripts/validate_project.sh" "$root" --quiet
