#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p Andeville.app/Contents/MacOS Andeville.app/Contents/Resources
cp Info.plist Andeville.app/Contents/Info.plist
for m in models/*.mlpackage; do xcrun coremlcompiler compile "$m" Andeville.app/Contents/Resources >/dev/null; done
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
# Re-signing the binary in place gets a running copy killed by macOS, so leave the new build running instead.
pkill -x Andeville 2>/dev/null && sleep 1 || true
open Andeville.app
