#!/bin/zsh
# Builds "build/Model Shelf.app" from source (needs Xcode or the Command Line Tools). Signed ad hoc for this Mac.
set -euo pipefail
cd "${0:a:h:h}"
swift build -c release
APP="build/Model Shelf.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/ModelShelf" "$APP/Contents/MacOS/ModelShelf"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
