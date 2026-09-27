#!/usr/bin/env bash
# Query the effective home's automatic-monitoring stop receipt.
#
# Usage: bin/fm-monitoring-stop.sh status --json
# Returns JSON with the status, stop time, diagnostic detail, and receipt path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-monitoring-stop-lib.sh
. "$SCRIPT_DIR/fm-monitoring-stop-lib.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
if [ "$#" -ne 2 ] || [ "$1" != status ] || [ "$2" != --json ]; then
  echo "usage: $(basename "$0") status --json" >&2
  exit 2
fi
fm_monitoring_stop_status "$STATE"
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
