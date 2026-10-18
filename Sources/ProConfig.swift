// Pitch Shift Pro: where to ask for a key, the price, and the secret keys are checked with.
// The secret is never in git: build.sh puts it in at build time, from PRO_KEY_SECRET or from
// ~/Library/Application Support/Pitch Shift Keys/secret.txt (made by tools/pro-keys.sh on the owner's Mac).
// With keySecret empty, nothing is locked and there is no Unlock button (a build from the public code just works).
enum ProConfig {
    static let keySecret = ""  // filled in by build.sh; leave empty here
    static let email = "cbsweetland@gmail.com"  // people email this address for a key
    static let price = "$5"
}
