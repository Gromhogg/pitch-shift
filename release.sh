#!/bin/zsh
# Builds the Mac installer (PitchShift.pkg) and app zip, and posts them as a new GitHub release.
# The Windows build on GitHub Actions then adds PitchShift-Setup.exe to the same release.
# Use: ./release.sh 2.0.0   (commit and push your changes first)
set -e
cd "${0:A:h}"
version=$1
if [[ -z $version ]]; then echo "Use: ./release.sh 1.2.3"; exit 1; fi
# Pitch Shift Pro: build.sh builds in the key secret from ~/Library/Application Support/Pitch Shift Keys/secret.txt
# (or PRO_KEY_SECRET), so the paid parts are locked. Without it the release would have nothing locked, so it stops,
# unless that's what's wanted: PRO_KEY_SECRET= ./release.sh 1.2.3 (everything free).
if [[ -z ${PRO_KEY_SECRET+x} && ! -s "$HOME/Library/Application Support/Pitch Shift Keys/secret.txt" ]]; then
  echo "No Pitch Shift Pro key secret on this Mac, so this release would have nothing locked."
  echo "Make it with tools/pro-keys.sh new \"name\" (or copy the saved Pitch Shift Keys folder back), or release"
  echo "with everything free: PRO_KEY_SECRET= ./release.sh $version"
  exit 1
fi
# The app's version only; the Pitch Shift Mic driver keeps its own version so updates don't restart Mac sound.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $version" Info.plist
./build.sh --no-install
packaging/make-pkg.sh $version
rm -f build/PitchShift.zip
ditto -c -k --keepParent "build/Pitch Shift.app" build/PitchShift.zip
gh release create "v$version" build/PitchShift.pkg build/PitchShift.zip --title "Pitch Shift $version" \
  --notes "Install or update: see the README. Mac: PitchShift.pkg. Windows (beta): PitchShift-Setup.exe (added a few minutes after the Mac files)."
