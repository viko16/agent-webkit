#!/bin/zsh
set -eu
cd "${0:A:h:h}"
configuration="${1:-debug}"
swift build -c "$configuration"
app="$PWD/.build/Agent WebKit.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp ".build/$configuration/browser" "$app/Contents/MacOS/browser"
cp packaging/Info.plist "$app/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$app"
print "App: $app"
print "CLI: $PWD/.build/$configuration/browser"
