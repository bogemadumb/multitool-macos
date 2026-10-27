#!/bin/bash
# Сборка release, сборка Multitul.app, подпись «Multitul Self-Signed», установка в ~/Applications,
# перезапуск LaunchAgent dev.multitool.app.
set -euo pipefail
cd "$(dirname "$0")"
SDK26=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if [ -d "$SDK26" ]; then export SDKROOT="$SDK26"; else echo "SDK 26.5 не найден, берётся системный (на SDK 27 без SwiftUIMacros сборка может упасть)"; fi

LABEL=dev.multitool.app
IDENTITY="Multitul Self-Signed"
KC="$HOME/Library/Keychains/multitul-signing.keychain-db"
PW_SERVICE="Multitul-signing-keychain"
VERSION=0.1.0
APP_BUILD="build/Multitul.app"
APP_DEST="$HOME/Applications/Multitul.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
COLLECTOR_LABEL=$LABEL.agent
COLLECTOR_PLIST="$HOME/Library/LaunchAgents/$COLLECTOR_LABEL.plist"

swift build -c release --product Multitul
swift build -c release --product multitul-ctl
BIN="$(swift build -c release --show-bin-path)/Multitul"
CTL_BIN="$(swift build -c release --show-bin-path)/multitul-ctl"

rm -rf "$APP_BUILD"
mkdir -p "$APP_BUILD/Contents/MacOS" "$APP_BUILD/Contents/Resources"
cp "$BIN" "$APP_BUILD/Contents/MacOS/Multitul"
cp "$CTL_BIN" "$APP_BUILD/Contents/Resources/multitul-ctl"
mkdir -p "$APP_BUILD/Contents/Resources/root"
cp root/install-root.sh root/multitul.sudoers "$APP_BUILD/Contents/Resources/root/"
cat > "$APP_BUILD/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$LABEL</string>
    <key>CFBundleName</key><string>Мультитул</string>
    <key>CFBundleDisplayName</key><string>Мультитул</string>
    <key>CFBundleExecutable</key><string>Multitul</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(date +%y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Мультитул управляет другими приложениями по вашей команде.</string>
    <key>NSCameraUsageDescription</key><string>Камера нужна модулям, которые показывают изображение с камеры.</string>
    <key>NSMicrophoneUsageDescription</key><string>Микрофон нужен модулям записи и управления звуком.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Запись звука системы нужна микшеру, чтобы менять громкость отдельных приложений.</string>
    <key>NSCalendarsUsageDescription</key><string>Календари нужны модулям, которые показывают ближайшие события.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Календари нужны модулям, которые показывают ближайшие события.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Напоминания нужны разделу «Календарь» острова, чтобы показывать ближайшие дела (только чтение).</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Папка загрузок нужна острову, чтобы показывать, что сейчас скачивается.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Bluetooth нужен модулям управления устройствами.</string>
</dict>
</plist>
PLIST

SIGN_PW=$(security find-generic-password -s "$PW_SERVICE" -w 2>/dev/null || true)
if [ -f "$KC" ] && [ -n "$SIGN_PW" ]; then
    printf 'unlock-keychain -p %s %s\n' "$SIGN_PW" "$KC" | security -i >/dev/null
    codesign --force --sign "$IDENTITY" --keychain "$KC" --options runtime \
        --identifier "$LABEL.ctl" "$APP_BUILD/Contents/Resources/multitul-ctl"
    codesign --force --sign "$IDENTITY" --keychain "$KC" --options runtime \
        --entitlements Multitul.entitlements --identifier "$LABEL" "$APP_BUILD"
    echo "подписан: $IDENTITY"
else
    echo "ОШИБКА: сертификата нет — сначала ./signing-setup.sh (ad-hoc подпись сбросила бы все разрешения)" >&2
    exit 1
fi
unset SIGN_PW
codesign --verify --strict "$APP_BUILD"

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Multitul"
UID_NUM=$(id -u)
if launchctl print "gui/$UID_NUM/$COLLECTOR_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID_NUM/$COLLECTOR_LABEL" || true
fi
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID_NUM/$LABEL" || true
    sleep 1
fi
# экземпляр, поднятый системой мимо launchd (после «Выйти и открыть снова»), bootout не трогает
pkill -x Multitul 2>/dev/null && sleep 1 || true
rm -rf "$APP_DEST"
ditto "$APP_BUILD" "$APP_DEST"
touch "$APP_DEST"

WAS_AUTOSTART=true
if [ -f "$AGENT_PLIST" ]; then
    [ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$AGENT_PLIST" 2>/dev/null || echo true)" = "false" ] && WAS_AUTOSTART=false
fi
sed "s|__HOME__|$HOME|g" launchd/$LABEL.plist > "$AGENT_PLIST"
if [ "$WAS_AUTOSTART" = "false" ]; then
    /usr/libexec/PlistBuddy -c 'Set :RunAtLoad false' "$AGENT_PLIST"
    /usr/libexec/PlistBuddy -c 'Delete :KeepAlive' "$AGENT_PLIST"
fi
plutil -lint "$AGENT_PLIST" >/dev/null
launchctl bootstrap "gui/$UID_NUM" "$AGENT_PLIST"
launchctl kickstart "gui/$UID_NUM/$LABEL" 2>/dev/null || true

sed "s|__HOME__|$HOME|g" launchd/$COLLECTOR_LABEL.plist > "$COLLECTOR_PLIST"
plutil -lint "$COLLECTOR_PLIST" >/dev/null
launchctl bootstrap "gui/$UID_NUM" "$COLLECTOR_PLIST"

echo "установлен: $APP_DEST"
echo "root-хелпер: sudo \"$APP_DEST/Contents/Resources/root/install-root.sh\" (один раз и после изменений multitul-ctl)"
codesign -dv "$APP_DEST" 2>&1 | grep -E "Identifier|Authority|flags|TeamIdentifier" || true
