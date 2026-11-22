#!/bin/zsh
# Pictures of the iOS player beside the Mac's, for looking at what iOS draws differently.
#
#   scripts/player-shots.sh                 # a few examples that use shaders, glass, text and video
#   scripts/player-shots.sh kit aurora      # only these gallery ids
#   PLAYER_DEVICE=<udid> scripts/player-shots.sh
#
# Builds the player for the simulator, opens each example in it (`-example <id>`), and writes
# build/player-shots/<id>.ios.png and <id>.mac.png (`papertool viewer`). An example that
# moves by itself is caught at a different moment on each side.
set -euo pipefail
cd "$(dirname "$0")/.."

ids=("$@")
(( ${#ids} )) || ids=(kit aurora lens video holo player weather)
out=build/player-shots
mkdir -p $out

device=${PLAYER_DEVICE:-$(xcrun simctl list devices available | grep "iPhone 17 Pro (" | tail -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')}
xcodegen generate --quiet
xcodebuild -project Tango.xcodeproj -scheme TangoPlayer -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath build build 2>&1 | grep -E "error|BUILD" | sort -u
xcrun simctl boot $device 2>/dev/null || true
xcrun simctl bootstatus $device -b >/dev/null
xcrun simctl install $device build/Build/Products/Debug-iphonesimulator/TangoPlayer.app

for id in $ids; do
  xcrun simctl launch --terminate-running-process $device com.tango.player -example $id >/dev/null
  sleep 4
  xcrun simctl io $device screenshot $out/$id.ios.png 2>/dev/null
  swift run papertool viewer $id $out/$id.mac.png 2>/dev/null | tail -1
done
echo "Pictures are in $out"
