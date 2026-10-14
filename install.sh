#!/bin/bash
# Installs Pitch Shift on a Mac: downloads the installer package and runs it (asks for your Mac password once).
# Use: curl -fsSL https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/install.sh | bash
set -euo pipefail

repo="Gromhogg/pitch-shift"

version="$(sw_vers -productVersion)"
major="${version%%.*}"
rest="${version#*.}"
minor="${rest%%.*}"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -lt 4 ]; }; then
  echo "Sorry, Pitch Shift needs macOS 14.4 or newer (this Mac has $version)."
  exit 1
fi

pkg="${PITCH_SHIFT_PKG:-}"  # for testing: a local PitchShift.pkg
if [ -z "$pkg" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Pitch Shift..."
  curl -fsSL "https://github.com/$repo/releases/latest/download/PitchShift.pkg" -o "$tmp/PitchShift.pkg"
  pkg="$tmp/PitchShift.pkg"
fi

echo "Type your Mac password to install Pitch Shift and Pitch Shift Mic (nothing shows while you type)."
sudo installer -pkg "$pkg" -target / >/dev/null

# A shortcut on the Desktop (replacing an old copy of version 1 there).
desktop="$HOME/Desktop/Pitch Shift.app"
if [ -e "$desktop" ] && [ ! -L "$desktop" ]; then rm -rf "$desktop"; fi
ln -sfn "/Applications/Pitch Shift.app" "$desktop" 2>/dev/null || true
echo "Installed Pitch Shift. It's in Applications and on your Desktop."
if [ -z "${PITCH_SHIFT_NO_OPEN:-}" ]; then open "/Applications/Pitch Shift.app"; fi
