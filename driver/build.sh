#!/bin/zsh
# Builds the "Pitch Shift Mic" audio driver (BlackHole with our own name and settings) into build/PitchShiftMic.driver,
# for both Apple silicon and Intel Macs.
set -e
cd "${0:A:h}/.."
out=build/PitchShiftMic.driver
rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
clang -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.4 -std=gnu11 -Os -Wall -Wno-unused-function \
  -DkDriver_Name='"PitchShiftMic"' -DkPlugIn_BundleID='"local.pitch-shift.mic"' -DkPlugIn_Icon='"PitchShiftMic.icns"' \
  -DkHas_Driver_Name_Format=0 -DkManufacturer_Name='"Pitch Shift"' -DkNumber_Of_Channels=2 \
  -DkDevice_Name='"Pitch Shift Mic"' -DkDevice_IsHidden=0 -DkDevice_HasInput=1 -DkDevice_HasOutput=0 \
  -DkDevice2_Name='"Pitch Shift Mic Output"' -DkDevice2_IsHidden=1 -DkDevice2_HasInput=0 -DkDevice2_HasOutput=1 \
  -DkCanBeDefaultSystemDevice=0 \
  driver/BlackHole.c -o "$out/Contents/MacOS/PitchShiftMic" \
  -framework CoreFoundation -framework CoreAudio -framework Accelerate
cp driver/Info.plist "$out/Contents/Info.plist"
cp AppIcon.icns "$out/Contents/Resources/PitchShiftMic.icns"
codesign --force --sign - --timestamp=none "$out"
