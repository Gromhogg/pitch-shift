// Auto-update: what updates are checked with. It's never in git: build.sh puts it in at build time, from
// UPDATE_PUBLIC_KEY or ~/Library/Application Support/Pitch Shift Keys/update-public.txt (made by tools/update-keys.sh
// setup on the owner's Mac). With publicKey empty, the app never checks for updates (a build from the public code).
enum UpdateConfig {
    // The public half of the owner's update key pair (64 hex characters): it checks updates but can't sign them.
    static let publicKey = ""  // filled in by build.sh; leave empty here
}
