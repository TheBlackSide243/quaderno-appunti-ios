#!/usr/bin/env bash
# Screenshots for the README, taken in the iOS Simulator with the demo notebooks.
# Needs the Xcode project generated (xcodegen generate). Usage: scripts/screenshots.sh <out dir>
set -euo pipefail

OUT="${1:-screenshots}"
BUNDLE=com.local.appunti
mkdir -p "$OUT"

xcodebuild -project Appunti.xcodeproj -scheme Appunti -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
APP="build/sim/Build/Products/Debug-iphonesimulator/Appunti.app"
test -d "$APP"

# The newest iOS runtime's device whose name matches the first pattern that finds one.
pick() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
pats = sys.argv[1:]
data = json.load(sys.stdin)["devices"]
def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
runtimes = sorted((rt for rt in data if "iOS" in rt), key=ver, reverse=True)
for p in pats:
    for rt in runtimes:
        for d in data[rt]:
            if re.search(p, d["name"]):
                print(d["udid"], d["name"], sep="|")
                sys.exit(0)
sys.exit(1)
' "$@"
}

shoot() {
  local kind="$1"; shift
  local found udid name
  found="$(pick "$@")" || { echo "no simulator for $kind"; return 0; }
  udid="${found%%|*}"; name="${found#*|}"
  echo "== $kind: $name ($udid)"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance dark || true
  xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 || true
  xcrun simctl install "$udid" "$APP"
  local screens="library editor pdf math ideas pages new search settings"
  for s in $screens; do
    xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
    xcrun simctl launch "$udid" "$BUNDLE" -demo -screen "$s" >/dev/null
    # first launch seeds the notebooks; the search waits for the text index
    case "$s" in library) sleep 14 ;; search) sleep 12 ;; *) sleep 8 ;; esac
    xcrun simctl io "$udid" screenshot --type=png "$OUT/$kind-$s.png" >/dev/null
    echo "   $kind-$s.png"
  done
  xcrun simctl shutdown "$udid" || true
}

shoot iphone '^iPhone \d+ Pro$' '^iPhone \d+$' 'iPhone'
shoot ipad 'iPad Pro 13' 'iPad Pro' 'iPad Air' 'iPad'
ls -la "$OUT"
