#!/bin/bash
# Installs the "Pitch Shift Mic" audio driver. Needs admin. Restarts the Mac's sound system (about one second
# of silence) only when the driver is new or changed.
# Use: sudo install-driver.sh [path/to/PitchShiftMic.driver]   (default: the copy inside Pitch Shift.app)
set -euo pipefail
src="${1:-$(cd "$(dirname "$0")/.." && pwd)/PlugIns/PitchShiftMic.driver}"
dest="/Library/Audio/Plug-Ins/HAL/PitchShiftMic.driver"
if [ ! -d "$src" ]; then echo "Can't find $src"; exit 1; fi
if [ -d "$dest" ] && cmp -s "$src/Contents/MacOS/PitchShiftMic" "$dest/Contents/MacOS/PitchShiftMic" \
   && cmp -s "$src/Contents/Info.plist" "$dest/Contents/Info.plist"; then
  exit 0
fi
mkdir -p /Library/Audio/Plug-Ins/HAL
rm -rf "$dest"
ditto "$src" "$dest"
chown -R root:wheel "$dest"
chmod -R go-w "$dest"
xattr -cr "$dest"   # a driver marked "downloaded from the internet" is silently not loaded
killall coreaudiod 2>/dev/null || true
