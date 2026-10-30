#!/bin/bash
# Signs Pitch Shift updates, for the owner. The app's installer runs as the Mac's admin, so the app opens a downloaded
# update only if it was signed with your update key.
#
#   tools/update-keys.sh setup                makes your update key pair, once (never replaces one that's there)
#   tools/update-keys.sh check                says whether the two halves belong together (release.sh runs this)
#   tools/update-keys.sh sign PKG VERSION     writes PKG.sig next to PKG (release.sh runs this)
#
# The private half (update-private.txt) signs updates, and the app holds only the public half (update-public.txt, built
# in by build.sh), which can check updates but can't sign them. Both live in
# ~/Library/Application Support/Pitch Shift Keys (only you can read it), next to the Pro keys but separate from them.
# Never put update-private.txt in git or send it to anyone: with it, someone could send every Pitch Shift user a fake
# update. Keep a copy of the whole folder somewhere safe: without update-private.txt, every copy of the app refuses all
# new updates, and people must install the next version by hand once.
#
# PITCH_SHIFT_KEYS_DIR=/some/folder uses another folder instead of the real one. UPDATE_PUBLIC_KEY, if set, is the public
# half that goes into the app (as in build.sh); check and sign make sure the private half matches it.
# Needs only what's on this Mac (bash and the Swift of the Command Line Tools); the work is done by update-keys.swift.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[[ -f $here/update-keys.swift ]] || { echo "update-keys.swift must be next to this script ($here)" >&2; exit 1; }
exec /usr/bin/swift "$here/update-keys.swift" "$@"
