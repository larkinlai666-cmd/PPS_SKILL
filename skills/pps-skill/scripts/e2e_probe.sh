#!/usr/bin/env bash
set -uo pipefail

# Minimal behavioral probe. REPLACE the assertion below with the real user
# path: launch the product, call the entry point, or exercise the installed
# copy. The gate requires a behavioral check that names a real artifact, but it
# cannot judge whether the assertion is strong enough — that is the owner's
# duty.
#
# This default asserts that the declared Main artifact is reachable AND that
# the project entry point named in PROJECT_MAP.md exists, which is the weakest
# honest end-to-end statement a fresh project can make.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/.." && pwd -P)"
if [[ $# -ge 1 && -d "$1" ]]; then
  root="$(cd "$1" && pwd -P)"
fi

main_rel="$(
  awk '
    $0 ~ "^##[[:space:]]+Hot State[[:space:]]*$" { inside=1; next }
    inside && /^##[[:space:]]/ { exit }
    inside && index($0, "- Main:") == 1 {
      sub("^- Main:[[:space:]]*", "")
      print
      exit
    }
  ' "$root/PROJECT_STATE.md"
)"

if [[ -z "$main_rel" ]]; then
  echo "e2e probe: no Main declared in Hot State" >&2
  exit 1
fi
if [[ ! -e "$root/$main_rel" ]]; then
  echo "e2e probe: Main artifact '$main_rel' is not reachable" >&2
  exit 1
fi
if ! grep -Eq '^\|[[:space:]]*C-' "$root/PROJECT_MAP.md"; then
  echo "e2e probe: PROJECT_MAP.md declares no component row" >&2
  exit 1
fi
echo "e2e probe: main artifact reachable and component map populated"
