#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
SDK26=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if [ -d "$SDK26" ]; then export SDKROOT="$SDK26"; else echo "SDK 26.5 не найден, берётся системный (на SDK 27 без SwiftUIMacros сборка может упасть)"; fi
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Vitrina"
APP="build/Vitrina.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vitrina"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.multitool.app.vitrina</string>
    <key>CFBundleName</key><string>Витрина Мультитула</string>
    <key>CFBundleExecutable</key><string>Vitrina</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier dev.multitool.app.vitrina "$APP"
codesign --verify --strict "$APP"
echo "собрано: $PWD/$APP"
