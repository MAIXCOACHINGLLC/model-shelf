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
# Built with plutil so any characters in the path are written safely.
rm -f "$PLIST"
plutil -create xml1 "$PLIST"
plutil -insert Label -string "$LABEL" "$PLIST"
plutil -insert ProgramArguments -array "$PLIST"
plutil -insert ProgramArguments.0 -string "$APP/Contents/MacOS/ModelShelf" "$PLIST"
plutil -insert RunAtLoad -bool YES "$PLIST"
plutil -insert KeepAlive -dictionary "$PLIST"
plutil -insert KeepAlive.SuccessfulExit -bool NO "$PLIST"
plutil -insert LimitLoadToSessionType -string Aqua "$PLIST"
plutil -insert ProcessType -string Interactive "$PLIST"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi
echo "Model Shelf is running. Look for the stack icon in the menu bar."
