#!/bin/bash
# Development helper: rebuilds, restarts the app on a scratch data folder with
# the snapshot hook on. `tools/dev.sh shot <folder>` writes window pictures.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# `tools/dev.sh do "<command>"` runs a command in the front window (see Debug.swift).
post() {
    /usr/bin/python3 - "$1" "$2" <<'PY' 2>/dev/null || swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(CommandLine.arguments[1]), object: CommandLine.arguments[2], userInfo: nil, deliverImmediately: true)' "$1" "$2"
import sys
from Foundation import NSDistributedNotificationCenter
NSDistributedNotificationCenter.defaultCenter().postNotificationName_object_userInfo_deliverImmediately_(sys.argv[1], sys.argv[2], None, True)
PY
}
if [ "${1:-}" = shot ]; then post com.mdenizay.mizu.snapshot "$2"; exit 0; fi
if [ "${1:-}" = do ]; then post com.mdenizay.mizu.do "$2"; exit 0; fi
if [ "${1:-}" = dump ]; then post com.mdenizay.mizu.dump ""; exit 0; fi
pkill -x Mizu 2>/dev/null || true
"$ROOT/build.sh" 2>&1 | grep -E "^/.*error:|error\\[|==> /" | cut -c1-300 || true
MIZU_DEBUG=1 MIZU_DATA="${MIZU_DATA:-MizuDev}" "$ROOT/dist/Mizu.app/Contents/MacOS/Mizu" >/tmp/mizu-dev.log 2>&1 &
