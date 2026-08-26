#!/usr/bin/env bash
# Append one self-observation line to $ROOT/.pps/fault-log.md.
#
# This is the PPS self-observation channel: when a PPS script notices an
# anomaly in itself or its environment (a degraded fallback, a missing tool,
# an internal surprise), it records one structured line here. The log is
# append-only, project-local, and read by the PPS author between real-world
# runs to turn field faults into review vectors and fixtures.
#
# The channel is strictly side-effect-free: it never changes any PPS check,
# never fails a gate, and every caller swallows its failure with `|| true` so
# a logging problem can never change the behaviour of the script that logged
# it. It writes one line and exits.
#
# Usage: fault_log.sh [ROOT] --type F-ENV --script NAME --message "TEXT"
set -uo pipefail

usage() {
  echo "Usage: fault_log.sh [ROOT] --type F-ENV|F-DEGRADED|F-PPS --script NAME --message TEXT"
}

root="."
fault_type=""
script_name=""
message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) fault_type="$2"; shift 2 ;;
    --script) script_name="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    *) root="$1"; shift ;;
  esac
done
[[ -n "$fault_type" && -n "$script_name" && -n "$message" ]] || {
  usage >&2
  exit 2
}

log_dir="$root/.pps"
log_file="$log_dir/fault-log.md"
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Best-effort only: a logging problem must never propagate to the caller.
mkdir -p "$log_dir" 2>/dev/null || exit 1
if [[ ! -f "$log_file" ]]; then
  {
    printf '# PPS Fault Log\n\n'
    printf 'Self-observation records: anomalies PPS noticed in itself or its environment.\n'
    printf 'Append-only; see references/self-observation.md.\n\n'
  } >"$log_file" 2>/dev/null || exit 1
fi
printf -- '- %s | %s | script: %s | engine: bash | %s\n' \
  "$timestamp" "$fault_type" "$script_name" "$message" >>"$log_file" 2>/dev/null || exit 1
