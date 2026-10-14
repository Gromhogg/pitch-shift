#!/bin/bash
# Removes Pitch Shift and Pitch Shift Mic from a Mac.
# Use: curl -fsSL https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/uninstall.sh | bash
set -uo pipefail
echo "Type your Mac password to remove Pitch Shift (nothing shows while you type)."
sudo /bin/bash -c '
  pkill -x PitchShift 2>/dev/null && sleep 1
  rm -rf "/Applications/Pitch Shift.app" /Library/Audio/Plug-Ins/HAL/PitchShiftMic.driver
  pkgutil --forget local.pitch-shift.pkg >/dev/null 2>&1
  killall coreaudiod 2>/dev/null
' || exit 1
desktop="$HOME/Desktop/Pitch Shift.app"
if [ -L "$desktop" ]; then rm "$desktop"; fi
defaults delete local.pitch-shift >/dev/null 2>&1
tccutil reset All local.pitch-shift >/dev/null 2>&1
echo "Pitch Shift is removed."
