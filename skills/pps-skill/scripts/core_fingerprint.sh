#!/usr/bin/env bash
set -uo pipefail

# core_fingerprint.sh [ROOT]
#
# Prints a 16-character sha256 fingerprint of the state a resume packet's
# anchor level must reflect: the objective, the red lines, the current package
# (with its Acceptance items), and the write boundary. Anything that changes
# the goal, the done-condition, or what may be written changes this fingerprint.
#
# Why this exists: .pps/last-packet records the fingerprint of the packet that
# was actually pulled. boundary_check --require-fresh-packet compares it with
# the disk. A forged timestamp is not enough to satisfy that check: faking the
# fingerprint requires reading these sections off the disk and hashing them,
# and reading them IS the re-anchoring the check exists to force. The cost of
# a fake equals the benefit of compliance.
#
# Assembly rule (byte-level parity with the PowerShell edition, pinned by
# fixture 055): every line of a section is emitted with its newline, then one
# extra newline closes the section. A section that is missing or empty still
# contributes exactly one closing newline.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root_input="${1:-$(cd "$script_dir/.." && pwd -P)}"
root="$(cd "$root_input" && pwd -P)"

section_body() {
  local file="$1"
  local section="$2"
  [[ -f "$file" ]] || return 0
  awk -v section="$section" '
    $0 == "## " section { inside=1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$file"
}

workset_boundary_lines() {
  [[ -f "$1" ]] || return 0
  awk '
    $0 == "## Workset Manifest" { inside=1; next }
    inside && /^## / { exit }
    inside && $0 ~ /^- (Read|Write|Verify|Excluded):/ { print }
  ' "$1"
}

# Objective and current package come first: they are the goal and the
# done-condition, the two things drift replaces. Red lines and the write
# boundary are the guardrails rot erases. Order is part of the input.
# Streamed through the hash directly: command substitution would strip the
# trailing newline and break byte parity with the PowerShell edition.
core_stream() {
  section_body "$root/PROJECT_STATE.md" "Objective"
  printf '\n'
  section_body "$root/AGENTS.md" "Red Lines"
  printf '\n'
  section_body "$root/CONTEXT.md" "Current Package"
  printf '\n'
  workset_boundary_lines "$root/CONTEXT.md"
  printf '\n'
}

if command -v sha256sum >/dev/null 2>&1; then
  core_stream | sha256sum | awk '{print $1}' | cut -c1-16
elif command -v shasum >/dev/null 2>&1; then
  core_stream | shasum -a 256 | awk '{print $1}' | cut -c1-16
else
  core_stream | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-16
fi
