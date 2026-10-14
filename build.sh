#!/bin/zsh
# Builds "Pitch Shift.app" and puts it on the Desktop.
set -e
cd "${0:A:h}"
if [[ ! -f /opt/homebrew/lib/librubberband.a ]]; then
  echo "Needs Rubber Band first: brew install rubberband"
  exit 1
fi
app=build/"Pitch Shift.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Rubber Band (brew install rubberband) is built into the app, so the app works on its own.
swiftc -O -swift-version 5 main.swift -o "$app/Contents/MacOS/PitchShift" \
  -import-objc-header rubberband.h -I/opt/homebrew/include \
  -Xlinker /opt/homebrew/lib/librubberband.a -Xlinker /opt/homebrew/opt/libsamplerate/lib/libsamplerate.a \
  -lc++ -framework Accelerate
if [[ ! -f AppIcon.icns ]]; then
  swift make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
rm -rf ~/Desktop/"Pitch Shift.app"
cp -R "$app" ~/Desktop/
echo "Built ~/Desktop/Pitch Shift.app"
