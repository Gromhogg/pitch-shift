#!/bin/zsh
# Makes build/PitchShift.pkg (the double-click installer) from build/Pitch Shift.app.
# Use: packaging/make-pkg.sh 2.0.0   (run ./build.sh --no-install first)
set -e
cd "${0:A:h}/.."
version=$1
if [[ -z $version ]]; then echo "Use: packaging/make-pkg.sh 1.2.3"; exit 1; fi
root=build/pkgroot
rm -rf $root build/component.pkg build/component.plist build/PitchShift.pkg
mkdir -p $root
ditto --norsrc --noextattr --noqtn "build/Pitch Shift.app" "$root/Pitch Shift.app"
pkgbuild --analyze --root $root build/component.plist
# Always install to /Applications (otherwise Installer may "update" an old copy wherever it finds one, like the Desktop).
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" build/component.plist >/dev/null 2>&1; do
  plutil -replace $i.BundleIsRelocatable -bool NO build/component.plist
  i=$((i + 1))
done
chmod +x packaging/scripts/*
# The newer compression macOS 14.4 can unpack: the same files, a smaller download (about 9 MB less, mostly the voices).
pkgbuild --root $root --component-plist build/component.plist --install-location /Applications \
  --scripts packaging/scripts --identifier local.pitch-shift.pkg --version $version \
  --compression latest --min-os-version 14.4 build/component.pkg
sed "s/VERSION/$version/" packaging/distribution.xml > build/distribution.xml
productbuild --distribution build/distribution.xml --package-path build build/PitchShift.pkg
echo "Built build/PitchShift.pkg"
