"""Reject a compiled app whose metadata cannot register its native surfaces."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
extension = app / "Contents/PlugIns/AXWidgetExtension.appex"
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["LSUIElement"] is True
assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["ax-widget"]
with (extension / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
result = subprocess.run(
    ["codesign", "-d", "--entitlements", "-", "--xml", str(extension)],
    capture_output=True, check=True,
)
entitlements = plistlib.loads(result.stdout)
assert entitlements["com.apple.security.app-sandbox"] is True
assert entitlements[
    "com.apple.security.temporary-exception.files.home-relative-path.read-only"
] == ["/Library/Application Support/ax-widget/"]
print("Verified widget registration, conversation URL scheme, and narrow read-only bridge.")
