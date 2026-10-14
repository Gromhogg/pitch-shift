#!/bin/zsh
# Builds the Mac installer (PitchShift.pkg) and app zip, and posts them as a new GitHub release.
# The Windows build on GitHub Actions then adds PitchShift-Setup.exe to the same release.
# Use: ./release.sh 2.0.0   (commit and push your changes first)
set -e
cd "${0:A:h}"
version=$1
if [[ -z $version ]]; then echo "Use: ./release.sh 1.2.3"; exit 1; fi
# The app's version only; the Pitch Shift Mic driver keeps its own version so updates don't restart Mac sound.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $version" Info.plist
./build.sh --no-install
packaging/make-pkg.sh $version
rm -f build/PitchShift.zip
ditto -c -k --keepParent "build/Pitch Shift.app" build/PitchShift.zip
gh release create "v$version" build/PitchShift.pkg build/PitchShift.zip --title "Pitch Shift $version" \
  --notes "Install or update: see the README. Mac: PitchShift.pkg. Windows (beta): PitchShift-Setup.exe (added a few minutes after the Mac files)."
