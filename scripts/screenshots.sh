#!/usr/bin/env bash
# Screenshots for the README, taken in the iOS Simulator with the demo notebooks.
# Needs the Xcode project generated (xcodegen generate).
# Usage: scripts/screenshots.sh <out dir> [iphone|ipad|duo]   (no second argument: all three)
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
  if [ "$kind" = duo ]; then
    # Two screens: --display=1 is the outer one (closed), --display=3 the inner one (open).
    # The simulator starts closed; switching the outer screen off makes iOS use the inner one.
    # Switching the outer screen off crashes the simulator's home screen (SpringBoard) on the
    # runners, so the open side is shot only when asked with DUO_SIDES containing "open".
    if [ "${DUO_SIDES:-closed}" != open ]; then pass "$udid" duo-closed 1; fi
    case "${DUO_SIDES:-closed}" in *open*) ;; *) xcrun simctl shutdown "$udid" || true; return 0 ;; esac
    xcrun simctl io "$udid" screenConfig --display=1 power off || true
    xcrun simctl io "$udid" screenConfig --display=3 power on || true
    # The home screen restarts on the inner screen: give it time before opening the app.
    sleep 30
    xcrun simctl io "$udid" enumerate 2>/dev/null | grep -E "Power state|Default (width|height)" || true
    pass "$udid" duo-open 3
  else
    pass "$udid" "$kind" ""
  fi
  xcrun simctl shutdown "$udid" || true
}

# One screenshot per demo screen: pass <udid> <file prefix> <display or empty>
pass() {
  local udid="$1" prefix="$2" display="$3"
  local screens="library editor pdf math ideas pages shapes ocr new covers search settings intro trash"
  for s in $screens; do
    xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
    local tries=0
    until xcrun simctl launch "$udid" "$BUNDLE" -demo -screen "$s" -AppleLanguages "(it)" -AppleLocale it_IT >/dev/null; do
      tries=$((tries + 1)); [ $tries -ge 4 ] && { echo "   $prefix-$s: the app did not open"; continue 2; }
      sleep 15
    done
    # first launch seeds the notebooks; the search waits for the text index
    case "$s" in library) sleep 14 ;; search) sleep 12 ;; *) sleep 8 ;; esac
    if [ -n "$display" ]; then
      xcrun simctl io "$udid" screenshot --type=png --display="$display" "$OUT/$prefix-$s.png" >/dev/null || true
    else
      xcrun simctl io "$udid" screenshot --type=png "$OUT/$prefix-$s.png" >/dev/null
    fi
    echo "   $prefix-$s.png"
  done
}

# The two-screen iPhone ("duo"): use a device of that type, creating one if the runtime has the
# type but no device. Prints the iPhone models so a missing one is easy to spot in the log.
duo_device() {
  echo "== iPhone models on this runner:"
  xcrun simctl list devicetypes | grep -i iphone || true
  pick 'Duo' 'Fold' 'Flip' >/dev/null && return 0
  local dtype runtime
  dtype="$(xcrun simctl list devicetypes -j | python3 -c '
import json, re, sys
for t in json.load(sys.stdin)["devicetypes"]:
    if re.search(r"Duo|Fold|Flip", t["name"]) and "iPhone" in t["name"]:
        print(t["identifier"]); break
')" || true
  runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["platform"] == "iOS"]
print(rts[-1]["identifier"] if rts else "")
')" || true
  if [ -n "$dtype" ] && [ -n "$runtime" ]; then
    xcrun simctl create "iPhone Duo shots" "$dtype" "$runtime" >/dev/null && echo "   created $dtype"
  else
    echo "   no two-screen iPhone type here"
  fi
}

ONLY="${2:-}"
if [ -z "$ONLY" ] || [ "$ONLY" = iphone ]; then shoot iphone '^iPhone \d+ Pro$' '^iPhone \d+$' 'iPhone'; fi
if [ -z "$ONLY" ] || [ "$ONLY" = ipad ]; then shoot ipad 'iPad Pro 13' 'iPad Pro' 'iPad Air' 'iPad'; fi
if [ -z "$ONLY" ] || [ "$ONLY" = duo ]; then duo_device; shoot duo 'Duo' 'Fold' 'Flip' 'iPhone Duo shots'; fi
# Crash reports of the app from the simulators, if any.
mkdir -p "$OUT/crashes"
find "$HOME/Library/Logs/DiagnosticReports" -iname 'Appunti*' -newer "$APP" -exec cp {} "$OUT/crashes/" \; 2>/dev/null || true
ls -la "$OUT" "$OUT/crashes"
