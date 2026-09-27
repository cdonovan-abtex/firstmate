#!/usr/bin/env bash
# Inspect or report the effective home's automatic-monitoring stop receipt.
#
# Usage:
#   bin/fm-monitoring-stop.sh status [--json]
#   bin/fm-monitoring-stop.sh blocks
#   bin/fm-monitoring-stop.sh report-once
#
# status always exits 0 and prints one of none, active, resumed, or malformed.
# --json additionally carries the stop time, diagnostic detail, and receipt path.
# blocks exits 0 only for active or malformed evidence; those are the two states
# in which every automatic watcher arm, re-arm, and repair prompt must stand
# down. report-once atomically claims one report per active stop identity (or
# malformed receipt revision) and stays silent after another caller reported it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-monitoring-stop-lib.sh
. "$SCRIPT_DIR/fm-monitoring-stop-lib.sh"

command=${1:-}
case "$command" in
  status)
    [ "$#" -le 2 ] || { echo "usage: $(basename "$0") status [--json]" >&2; exit 2; }
    format=${2:-}
    [ -z "$format" ] || [ "$format" = --json ] || { echo "usage: $(basename "$0") status [--json]" >&2; exit 2; }
    fm_monitoring_stop_status "$STATE"
    if [ "$format" = --json ]; then
      if command -v jq >/dev/null 2>&1; then
        jq -n \
          --arg status "$FM_MONITORING_STOP_STATUS" \
          --arg time "$FM_MONITORING_STOP_TIME" \
          --arg detail "$FM_MONITORING_STOP_DETAIL" \
          --arg receipt "$FM_MONITORING_STOP_RECEIPT" \
          '{status:$status,time:$time,detail:$detail,receipt:$receipt}'
      else
        printf '{"status":"malformed","time":"","detail":"jq is required to validate the receipt","receipt":""}\n'
      fi
    else
      printf '%s\n' "$FM_MONITORING_STOP_STATUS"
    fi
    ;;
  blocks)
    [ "$#" -eq 1 ] || { echo "usage: $(basename "$0") blocks" >&2; exit 2; }
    fm_monitoring_stop_blocks "$STATE"
    ;;
  report-once)
    [ "$#" -eq 1 ] || { echo "usage: $(basename "$0") report-once" >&2; exit 2; }
    fm_monitoring_stop_report_once "$STATE"
    ;;
  -h|--help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "usage: $(basename "$0") {status [--json]|blocks|report-once}" >&2
    exit 2
    ;;
esac
