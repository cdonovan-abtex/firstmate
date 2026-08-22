#!/usr/bin/env bash
# fm-run-long-child.sh - run one Firstmate-owned long child with the host's
# bounded power assertion.
#
# Usage:
#   fm-run-long-child.sh <command> [arguments...]
#
# On macOS, this uses caffeinate's utility mode so the assertion owner exists
# exactly as long as the command it starts. The system-sleep assertion (-s) is
# effective only on AC power; -i and -m still request idle-system and disk-idle
# protection on battery, but this interface does not claim that they prevent a
# forced or maintenance sleep there. Other platforms execute the command
# directly because this macOS assertion interface does not apply. A host whose
# kernel identity cannot be read is refused loudly rather than launched
# unprotected, because that fallback would silently drop the assertion on a Mac.
#
# FM_LONG_CHILD_CAFFEINATE_BIN overrides /usr/bin/caffeinate for hermetic
# public-interface regression tests. Production callers leave it unset.
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: fm-run-long-child.sh <command> [arguments...]" >&2
  exit 2
fi

if ! host_kernel=$(uname -s 2>/dev/null) || [ -z "$host_kernel" ]; then
  echo "error: long-child protection requires a host kernel identity from uname -s" >&2
  exit 1
fi

if [ "$host_kernel" = Darwin ]; then
  caffeinate_bin=${FM_LONG_CHILD_CAFFEINATE_BIN:-/usr/bin/caffeinate}
  if [ ! -x "$caffeinate_bin" ]; then
    echo "error: macOS long-child protection requires executable caffeinate at $caffeinate_bin" >&2
    exit 1
  fi
  exec "$caffeinate_bin" -s -i -m "$@"
fi

exec "$@"
