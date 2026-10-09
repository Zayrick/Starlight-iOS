#!/bin/bash
#
# Captures the App Store screenshots in every language on iPhone and iPad,
# using the app's sample data instead of a real host.
#
# Usage: scripts/screenshots.sh [output directory]
# IPHONE / IPAD pick the simulators by name, SHOT_LANG limits the languages.
#
# The default simulators have to be created once:
#   xcrun simctl create "Shot iPhone 6.9" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
#   xcrun simctl create "Shot iPad 13" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB
#
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$(mkdir -p "${1:-Screenshots}" && cd "${1:-Screenshots}" && pwd)"
DERIVED=/tmp/starlight-shots-dd
DEVICES=("${IPHONE:-Shot iPhone 6.9}" "${IPAD:-Shot iPad 13}")

xcodebuild build-for-testing -quiet \
  -project Starlight.xcodeproj -scheme Starlight \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO

for device in "${DEVICES[@]}"; do
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" >/dev/null
  xcrun simctl status_bar "$device" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100

  TEST_RUNNER_SHOT_DIR="$OUT" TEST_RUNNER_SHOT_LANG="${SHOT_LANG:-}" \
  xcodebuild test-without-building -quiet \
    -project Starlight.xcodeproj -scheme Starlight \
    -destination "platform=iOS Simulator,name=$device" \
    -derivedDataPath "$DERIVED" -parallel-testing-enabled NO \
    -only-testing:StarlightUITests/AppStoreScreenshots/testScreenshots

  xcrun simctl status_bar "$device" clear
done

echo "Screenshots saved to $OUT"
