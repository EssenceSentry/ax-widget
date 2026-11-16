#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-Release}"
mkdir -p dist
if /usr/bin/xcodebuild -version >/dev/null 2>&1 && command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
    xcodebuild -project AXWidget.xcodeproj -scheme AXWidget -configuration "$configuration" \
        -derivedDataPath build/xcode -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
    source_app="build/xcode/Build/Products/$configuration/AXWidget.app"
    ditto "$source_app" 'dist/AX Widget.app'
    codesign --force --sign - --entitlements Config/Widget.entitlements \
        'dist/AX Widget.app/Contents/PlugIns/AXWidgetExtension.appex'
else
    echo 'Building floating app with Command Line Tools. System widgets require the Xcode build.'
    swift build -c "$(printf '%s' "$configuration" | tr '[:upper:]' '[:lower:]')" --jobs 2 --product AXWidget
    binaries="$(swift build -c "$(printf '%s' "$configuration" | tr '[:upper:]' '[:lower:]')" --show-bin-path)"
    mkdir -p 'dist/AX Widget.app/Contents/MacOS' 'dist/AX Widget.app/Contents/Resources'
    cp "$binaries/AXWidget" 'dist/AX Widget.app/Contents/MacOS/AXWidget'
    cp Config/AppInfo.plist 'dist/AX Widget.app/Contents/Info.plist'
    for resource in "$binaries"/*.bundle; do
        if [[ -d "$resource" ]]; then ditto "$resource" "dist/AX Widget.app/Contents/Resources/$(basename "$resource")"; fi
    done
fi
codesign --force --sign - --options runtime 'dist/AX Widget.app'
codesign --verify --deep --strict 'dist/AX Widget.app'
echo 'Built dist/AX Widget.app'
