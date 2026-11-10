#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p Andeville.app/Contents/MacOS Andeville.app/Contents/Resources
cp Info.plist Andeville.app/Contents/Info.plist
for m in models/*.mlpackage; do xcrun coremlcompiler compile "$m" Andeville.app/Contents/Resources >/dev/null; done
swiftc -swift-version 5 Andeville.swift -o Andeville.app/Contents/MacOS/Andeville
codesign --force --sign "Faytai Local Signing" --identifier com.ggear.faytai Andeville.app
Andeville.app/Contents/MacOS/Andeville --self-check
