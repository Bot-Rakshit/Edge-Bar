#!/bin/bash
# Builds EdgePad.app, signs it, installs it to ~/Applications and launches it.
#   ./build.sh            build + install + launch
#   ./build.sh --no-run   build + install only
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/EdgePad.app
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EdgePad "$APP/Contents/MacOS/EdgePad"
cp Info.plist "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/EdgePad" --make-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# A real signing identity keeps the Accessibility grant valid across rebuilds; ad-hoc otherwise.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier com.rakshit.edgepad "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"

pkill -x EdgePad 2>/dev/null && sleep 0.5 || true
mkdir -p ~/Applications
rm -rf ~/Applications/EdgePad.app
cp -R "$APP" ~/Applications/EdgePad.app
echo "Installed ~/Applications/EdgePad.app"

if [[ "${1:-}" != "--no-run" ]]; then
  open ~/Applications/EdgePad.app
fi
