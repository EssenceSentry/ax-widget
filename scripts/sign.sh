#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-dist/AX Widget.app}"
identity="${AX_WIDGET_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^[[:space:]]*[0-9]+\) ([A-Fa-f0-9]{40}) "AX Widget Local Signing"$/\1/p')"
fi
identity="${identity:--}"
extension="$app/Contents/PlugIns/AXWidgetExtension.appex"
if [[ -d "$extension" ]]; then
    codesign --force --sign "$identity" --entitlements Config/Widget.entitlements "$extension"
fi
codesign --force --sign "$identity" --options runtime "$app"
codesign --verify --deep --strict "$app"
if [[ "$identity" == '-' ]]; then
    echo 'Signed ad hoc; changes require renewed Accessibility approval.'
else
    echo "Signed with persistent identity: $identity"
fi
