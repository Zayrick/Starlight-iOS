#!/bin/bash
set -euo pipefail

# Xcode projects need their actual compiler flags and built modules for indexing.
# https://github.com/SolaWing/xcode-build-server#usage
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v xcode-build-server >/dev/null 2>&1; then
    echo "Install the Xcode build server first: brew install xcode-build-server" >&2
    exit 1
fi

cd "$workspace_root"

# Keep the editor's iOS Simulator index separate from other Xcode destinations.
build_root="$workspace_root/.build/vscode/DerivedData"
mkdir -p "$build_root"
xcode-build-server config \
    -workspace "$workspace_root/Starlight.xcodeproj/project.xcworkspace" \
    -scheme Starlight \
    --build_root "$build_root"

# A result bundle makes xcodebuild emit the activity log the build server reads.
# Each build needs a new bundle path; xcodebuild cannot overwrite an existing one.
result_dir="$(mktemp -d "$workspace_root/.build/vscode/result.XXXXXX")"
xcodebuild \
    -project "$workspace_root/Starlight.xcodeproj" \
    -scheme Starlight \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_root" \
    -resultBundlePath "$result_dir/Build.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=YES \
    build
