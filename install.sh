#!/bin/bash
# Installs Pitch Shift: downloads the latest version and puts it on your Desktop.
# Use: curl -fsSL https://raw.githubusercontent.com/Gromhogg/pitch-shift/main/install.sh | bash
set -euo pipefail

repo="Gromhogg/pitch-shift"
dest="${PITCH_SHIFT_DIR:-$HOME/Desktop}"
app="$dest/Pitch Shift.app"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Sorry, Pitch Shift needs a Mac with Apple silicon (M1 or newer)."
  exit 1
fi
version="$(sw_vers -productVersion)"
major="${version%%.*}"
rest="${version#*.}"
minor="${rest%%.*}"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -lt 4 ]; }; then
  echo "Sorry, Pitch Shift needs macOS 14.4 or newer (this Mac has $version)."
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading Pitch Shift..."
curl -fsSL "https://github.com/$repo/releases/latest/download/PitchShift.zip" -o "$tmp/PitchShift.zip"
ditto -x -k "$tmp/PitchShift.zip" "$tmp"

# Replacing an old copy: close it first if it's open.
if [ -e "$app" ]; then
  if pkill -x PitchShift 2>/dev/null; then sleep 1; fi
  rm -rf "$app"
fi
mkdir -p "$dest"
mv "$tmp/Pitch Shift.app" "$app"
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

echo "Installed Pitch Shift: $app"
if [ -z "${PITCH_SHIFT_NO_OPEN:-}" ]; then open "$app"; fi
