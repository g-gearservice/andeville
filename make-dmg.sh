#!/bin/sh
# Build Andeville and package it.
#   ./make-dmg.sh           → builds Andeville.app and a Andeville-<version>.dmg to hand out (drag to Applications)
#   ./make-dmg.sh install   → builds and swaps the copy in /Applications, then relaunches (easy update)
set -e
cd "$(dirname "$0")"

./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

if [ "$1" = "install" ]; then
  pkill -x Andeville 2>/dev/null || true
  pkill -x Faytai 2>/dev/null || true   # the app's old name
  sleep 1
  rm -rf /Applications/Faytai.app
  rm -rf /Applications/Andeville.app
  cp -R Andeville.app /Applications/Andeville.app
  open /Applications/Andeville.app
  echo "Installed Andeville $VER to /Applications and relaunched."
  exit 0
fi

STAGE=$(mktemp -d)
cp -R Andeville.app "$STAGE/Andeville.app"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target inside the DMG
DMG="Andeville-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "Andeville $VER" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
