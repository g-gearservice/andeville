#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p Andeville.app/Contents/MacOS Andeville.app/Contents/Resources
cp Info.plist Andeville.app/Contents/Info.plist
# The app icon, drawn by make-icon.swift (run it again after changing the icon).
cp Andeville.icns Andeville.app/Contents/Resources/
for m in models/*.mlpackage; do xcrun coremlcompiler compile "$m" Andeville.app/Contents/Resources >/dev/null; done
# Apple's AR models of the AirPods (apple.com, "View in AR"), turned in the notch when they connect. Not in git.
cp AirPods3D/*.usdz Andeville.app/Contents/Resources/ 2>/dev/null || true
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" Andeville.swift -o Andeville.app/Contents/MacOS/Andeville
# Now Playing reader, loaded into /usr/bin/perl at run time (see NowPlaying in Andeville.swift).
clang -dynamiclib -fobjc-arc -framework Foundation -target "$(uname -m)-apple-macos14.0" NowPlaying.m -o Andeville.app/Contents/Resources/libnowplaying.dylib
# Controls for the Mac's Control Center and menu bar (WidgetKit, macOS 26+), signed sandboxed before the app around it.
X=Andeville.app/Contents/PlugIns/AndevilleControls.appex/Contents
mkdir -p "$X/MacOS"
cp Controls/Info.plist "$X/Info.plist"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -parse-as-library -application-extension Controls/AndevilleControls.swift -o "$X/MacOS/AndevilleControls"
codesign --force --sign "Faytai Local Signing" --identifier com.ggear.faytai.controls --entitlements Controls/Controls.entitlements Andeville.app/Contents/PlugIns/AndevilleControls.appex
codesign --force --sign "Faytai Local Signing" --identifier com.ggear.faytai Andeville.app
Andeville.app/Contents/MacOS/Andeville --self-check
# Into /Applications, where the login item opens it. Swapped in by renames, never copied over the running copy
# (rewriting a running app's files gets it killed): that copy sees the newer build within seconds and relaunches
# into it on its own, the keychain handed over first (applicationDidFinishLaunching). Started when none is running.
DEST=/Applications/Andeville.app
TMP=$(mktemp -d /Applications/.Andeville-install.XXXXXX)
ditto Andeville.app "$TMP/Andeville.app"
if [ -d "$DEST" ]; then mv "$DEST" "$TMP/old.app"; fi
mv "$TMP/Andeville.app" "$DEST"
rm -rf "$TMP"
pgrep -x Andeville >/dev/null || open "$DEST"
