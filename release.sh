#!/bin/zsh
# Builds the app and posts it as a new GitHub release, which install.sh then downloads.
# Use: ./release.sh 1.0.1   (commit and push your changes first)
set -e
cd "${0:A:h}"
version=$1
if [[ -z $version ]]; then echo "Use: ./release.sh 1.2.3"; exit 1; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" Info.plist
./build.sh
rm -f build/PitchShift.zip
ditto -c -k --keepParent "build/Pitch Shift.app" build/PitchShift.zip
gh release create "v$version" build/PitchShift.zip --title "Pitch Shift $version" --notes "Install or update: see the README."
