#!/bin/zsh
# Builds Model Shelf, puts it in ~/Applications, and adds a login item (a launchd job) that starts it at login and
# brings it back if it crashes. Run again to update. Nothing here needs admin rights.
set -euo pipefail
cd "${0:a:h:h}"
LABEL=io.github.maxketamine-spec.ModelShelf
APP="$HOME/Applications/Model Shelf.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
./scripts/build-app.sh
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP" && cp -R "build/Model Shelf.app" "$APP"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/ModelShelf</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
echo "Model Shelf is running. Look for the stack icon in the menu bar."
