#!/bin/zsh
# Holds the iOS shelf against real SwiftUI.
#
# Builds the reference app for the iOS Simulator, opens every case in it and takes a
# picture, then has papertool lay tango's own component over each one. The report
# and its pictures go to build/reference/redline (report.md).
#
#   Reference/run.sh              every case
#   Reference/run.sh tab-bar      only these
#   REFERENCE_DEVICE=<udid>       another simulator; the newest iPhone 17 Pro otherwise
#   REFERENCE_KEEP=1              compare against the pictures already taken
#   REFERENCE_DARK=1              in dark appearance: pictures in shots-dark, the report in redline-dark
#   REFERENCE_MOTION=1            the moving cases instead: each is recorded as it changes (motion/<id>.mov),
#                                 and the report of how each moves goes to motion-redline
set -e
cd "$(dirname "$0")/.."
out=build/reference
appearance=light; suffix=""; dark=""
[[ -n "$REFERENCE_DARK" ]] && { appearance=dark; suffix="-dark"; dark="--dark" }
shots=shots; report=redline; compare=redline; list=--cases
[[ -n "$REFERENCE_MOTION" ]] && { shots=motion; report=motion-redline; compare=redline-motion; list=--motions }
mkdir -p $out/$shots$suffix $out/PaperReference.app

swift build --product papertool 2>&1 | grep -E "error|Compiling|Build complete" | tail -1
tool=$(swift build --product papertool --show-bin-path)/papertool
cases=("$@")
[[ ${#cases} -eq 0 ]] && cases=($($tool redline $list))

if [[ -z "$REFERENCE_KEEP" ]]; then
  device=${REFERENCE_DEVICE:-$(xcrun simctl list devices available | grep "iPhone 17 Pro (" | tail -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')}
  [[ -z "$device" ]] && { echo "No iPhone 17 Pro simulator is installed."; exit 1 }
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  xcrun swiftc -sdk "$sdk" -target arm64-apple-ios26.0-simulator -parse-as-library -O \
    Reference/ReferenceApp.swift -o $out/PaperReference.app/PaperReference
  cp Reference/Info.plist $out/PaperReference.app/
  codesign -s - --force $out/PaperReference.app 2>/dev/null

  xcrun simctl boot $device 2>/dev/null || true
  xcrun simctl bootstatus $device -b >/dev/null
  # As a phone is out of the box (light, unless dark was asked for), text at its default size, a full status bar.
  xcrun simctl ui $device appearance $appearance
  xcrun simctl ui $device content_size large
  xcrun simctl status_bar $device override --time "9:41" --batteryState discharging --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcrun simctl install $device $out/PaperReference.app
  for id in $cases; do
    xcrun simctl launch --terminate-running-process $device com.heyadam.tango.reference -case $id >/dev/null
    if [[ -n "$REFERENCE_MOTION" ]]; then
      # The app makes its change 5 seconds after it opens (`MotionCase`). A recording takes
      # a second or two to start and may catch the end of the launch; the clip begins at the
      # frame the screen held longest (`Redline.clip(ofVideo:)`), so keep it going well past
      # the change.
      sleep 1
      rm -f $out/$shots$suffix/$id.mov
      xcrun simctl io $device recordVideo --codec=h264 --force $out/$shots$suffix/$id.mov >/dev/null 2>&1 &
      recorder=$!
      sleep 10
      kill -INT $recorder; wait $recorder 2>/dev/null || true
      echo "recorded $id"
    else
      # Long enough for the launch screen to go and a presented alert to settle.
      sleep 4.5
      xcrun simctl io $device screenshot $out/$shots$suffix/$id.png >/dev/null 2>&1
      echo "took $id"
    fi
  done
  xcrun simctl terminate $device com.heyadam.tango.reference 2>/dev/null || true
  xcrun simctl ui $device appearance light
fi

$tool $compare $out/$shots$suffix $out/$report$suffix $cases $dark
