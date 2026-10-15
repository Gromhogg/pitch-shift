#!/bin/zsh
# Builds "Pitch Shift.app" (with the Pitch Shift Mic driver inside) into build/, then installs it in /Applications
# with a shortcut on the Desktop. Use ./build.sh --no-install to only build.
set -e
cd "${0:A:h}"
# Rubber Band and libsamplerate for Apple silicon and Intel (needs brew install rubberband).
./libs/build.sh
app=build/"Pitch Shift.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"

./driver/build.sh
ditto build/PitchShiftMic.driver "$app/Contents/PlugIns/PitchShiftMic.driver"

# The app is built twice, for Apple silicon (arm64) and Intel (x86_64), both for macOS 14.4 or newer,
# and joined into one file.
rm -rf build/obj
for arch in arm64 x86_64; do
  obj=build/obj/$arch
  mkdir -p $obj
  # The C and C++ parts: the sound ring and the Advanced processing engine (Sources/Advanced).
  clang -arch $arch -mmacosx-version-min=14.4 -O2 -c Sources/AudioRing.c -o $obj/AudioRing.o
  for f in Sources/Advanced/*.cpp; do
    clang++ -arch $arch -mmacosx-version-min=14.4 -O2 -std=c++17 -Ibuild/libs/include -c "$f" -o "$obj/${f:t:r}.o"
  done
  # The voice changer: Natural mode (plain C++) and Realistic mode (Core ML, Objective-C++).
  for f in Sources/Voice/*.cpp; do
    clang++ -arch $arch -mmacosx-version-min=14.4 -O2 -std=c++17 -c "$f" -o "$obj/${f:t:r}.o"
  done
  for f in Sources/Voice/*.mm; do
    clang++ -arch $arch -mmacosx-version-min=14.4 -O2 -std=c++17 -fobjc-arc -c "$f" -o "$obj/${f:t:r}.o"
  done
  # Rubber Band is built into the app, so the app works on its own.
  swiftc -target $arch-apple-macos14.4 -O -swift-version 5 Sources/*.swift $obj/*.o -o $obj/PitchShift \
    -import-objc-header Sources/Bridging.h -Ibuild/libs/include \
    -Xlinker build/libs/lib/librubberband.a -Xlinker build/libs/lib/libsamplerate.a -lc++ -framework Accelerate \
    -framework CoreML
done
lipo -create build/obj/arm64/PitchShift build/obj/x86_64/PitchShift -output "$app/Contents/MacOS/PitchShift"

if [[ ! -f AppIcon.icns ]]; then
  swift make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns LICENSE packaging/install-driver.sh build/libs/lib/libsamplerate-COPYING "$app/Contents/Resources/"
# The voice changer's voices (settings, credits and, later, the Realistic models).
ditto voices "$app/Contents/Resources/Voices"
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
