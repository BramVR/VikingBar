#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-debug}"
swift build -c "$configuration" --product VikingBarApp
bin_path="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/.build/app/VikingBar.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$bin_path/VikingBarApp" "$bundle/Contents/MacOS/VikingBarApp"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VikingBarApp</string>
<key>CFBundleIdentifier</key><string>be.bram.vikingbar</string>
<key>CFBundleName</key><string>VikingBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$bundle"
