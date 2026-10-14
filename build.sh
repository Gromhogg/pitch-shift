#!/bin/zsh
# Builds "Pitch Shift.app" (with the Pitch Shift Mic driver inside) into build/, then installs it in /Applications
# with a shortcut on the Desktop. Use ./build.sh --no-install to only build.
set -e
cd "${0:A:h}"
if [[ ! -f /opt/homebrew/lib/librubberband.a ]]; then
  echo "Needs Rubber Band first: brew install rubberband"
  exit 1
fi
app=build/"Pitch Shift.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"

./driver/build.sh
ditto build/PitchShiftMic.driver "$app/Contents/PlugIns/PitchShiftMic.driver"

# The C and C++ parts: the sound ring and the Advanced processing engine (Sources/Advanced).
rm -rf build/obj
mkdir -p build/obj
clang -O2 -c Sources/AudioRing.c -o build/obj/AudioRing.o
for f in Sources/Advanced/*.cpp; do
  clang++ -O2 -std=c++17 -I/opt/homebrew/include -c "$f" -o "build/obj/${f:t:r}.o"
done

# Rubber Band (brew install rubberband) is built into the app, so the app works on its own.
swiftc -O -swift-version 5 Sources/*.swift build/obj/*.o -o "$app/Contents/MacOS/PitchShift" \
  -import-objc-header Sources/Bridging.h -I/opt/homebrew/include \
  -Xlinker /opt/homebrew/lib/librubberband.a -Xlinker /opt/homebrew/opt/libsamplerate/lib/libsamplerate.a \
  -lc++ -framework Accelerate

if [[ ! -f AppIcon.icns ]]; then
  swift make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns LICENSE packaging/install-driver.sh "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
[[ "$1" == "--no-install" ]] && exit 0

# Install here: the app in /Applications, a shortcut on the Desktop (replacing an old real copy there).
if [[ -e "/Applications/Pitch Shift.app" && ! -w "/Applications/Pitch Shift.app/Contents" ]]; then
  echo "Pitch Shift in Applications was put there by the installer package. Replace it with:"
  echo "  packaging/make-pkg.sh 0.0.0-dev && sudo installer -pkg build/PitchShift.pkg -target /"
  exit 1
fi
pkill -x PitchShift && sleep 1 || true
rm -rf "/Applications/Pitch Shift.app"
ditto "$app" "/Applications/Pitch Shift.app"
desktop=~/Desktop/"Pitch Shift.app"
[[ -e $desktop && ! -L $desktop ]] && rm -rf $desktop
ln -sfn "/Applications/Pitch Shift.app" $desktop
if ! cmp -s build/PitchShiftMic.driver/Contents/MacOS/PitchShiftMic /Library/Audio/Plug-Ins/HAL/PitchShiftMic.driver/Contents/MacOS/PitchShiftMic 2>/dev/null; then
  echo "Pitch Shift Mic is new or changed. Install it with: sudo packaging/install-driver.sh build/PitchShiftMic.driver"
fi
echo "Installed /Applications/Pitch Shift.app (shortcut on the Desktop)"
