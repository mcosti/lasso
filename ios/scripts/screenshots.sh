#!/bin/sh
# Generates the App Store screenshots in the Simulator.
#
#   ios/scripts/screenshots.sh            # iPhone 17 Pro Max (6.9") only
#   ios/scripts/screenshots.sh "iPhone 17 Pro Max" "iPhone 16 Plus"
#
# Raw captures land in <private repo>/marketing/screenshots/captured/<device>/,
# then that repo's tools/frame_screenshots.py frames them for the store.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(cd .. && pwd)
# Screenshots are marketing material and live in the nested private repo.
PRIVATE="${LASSO_PRIVATE:-$ROOT/private}"
OUT="$PRIVATE/marketing/screenshots/captured"
DEVICES="${*:-iPhone 17 Pro Max}"

xcodegen generate >/dev/null

# ${*:-} collapses the list; iterate over the original arguments instead.
[ $# -gt 0 ] || set -- "iPhone 17 Pro Max"
for DEVICE in "$@"; do
  UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
devs=[d for r in json.load(sys.stdin)['devices'].values() for d in r if d['name']=='$DEVICE']
print(devs[0]['udid'] if devs else '')")
  [ -n "$UDID" ] || { echo "no simulator named $DEVICE"; exit 1; }
  echo "== $DEVICE ($UDID)"
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  xcrun simctl ui "$UDID" appearance dark
  xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --operatorName "" --wifiMode active --wifiBars 3 --dataNetwork 5g

  SLUG=$(echo "$DEVICE" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
  RESULT="build/screenshots-$SLUG.xcresult"
  rm -rf "$RESULT"
  xcodebuild test -scheme Lasso -destination "id=$UDID" -derivedDataPath build/DerivedData \
    -only-testing:LassoUITests -resultBundlePath "$RESULT" -quiet 2>&1 | grep -E "error:|failed|passed|Executed" || true

  DEST="$OUT/$SLUG"
  rm -rf "$DEST" && mkdir -p "$DEST"
  TMP=$(mktemp -d)
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$TMP" >/dev/null
  python3 - "$TMP" "$DEST" <<'PY'
import json, shutil, sys, os
src, dest = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(src, "manifest.json")))
for test in manifest:
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        # "01-home_1_..." -> "01-home.png"
        base = name.split("_")[0]
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dest, base + ".png"))
        print("captured", base)
PY
  rm -rf "$TMP"
  xcrun simctl status_bar "$UDID" clear
done

if [ -f "$PRIVATE/tools/frame_screenshots.py" ]; then
  python3 "$PRIVATE/tools/frame_screenshots.py"
else
  echo "captures in $OUT (no framing script found)"
fi
