#!/usr/bin/env bash
# Builds Polso.app into ~/Applications (override with APP=...). `--login` also installs a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --build-system native
APP="${APP:-$HOME/Applications/Polso.app}"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp .build/release/Polso "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.polso</string>
  <key>CFBundleName</key><string>Polso</string>
  <key>CFBundleExecutable</key><string>Polso</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

if [[ "${1:-}" == "--login" ]]; then
  PL="$HOME/Library/LaunchAgents/local.polso.plist"
  cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.polso</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Polso</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/local.polso" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PL"
  echo "login agent installed: $PL"
fi
