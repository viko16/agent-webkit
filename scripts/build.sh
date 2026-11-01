#!/bin/zsh
set -eu
cd "${0:A:h:h}"
configuration="${1:-debug}"
swift build -c "$configuration"
app="$PWD/.build/Agent WebKit.app"
if [[ -e "$app" ]]; then
    swift -e 'import Foundation; try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), resultingItemURL: nil)' "$app"
fi
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
cp ".build/$configuration/awb" "$app/Contents/MacOS/awb"
cp packaging/Info.plist "$app/Contents/Info.plist"
version="$(".build/$configuration/awb" version | plutil -extract result.version raw -o - -)"
plutil -insert CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$version" "$app/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$app/Contents/Resources/LICENSE"
swift scripts/make_icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
print "App: $app"
print "CLI: $PWD/.build/$configuration/awb"
