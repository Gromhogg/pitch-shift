// Pitch Shift Pro's unlock server, its public key and the payment link. None of these is a secret (the private key
// stays on the server). build.sh replaces them for a test build when PRO_SERVER, PRO_PUBLIC_KEY or PRO_BUY_URL is set.
// With publicKey empty, nothing is locked and there is no Unlock button (a build without the server set up).
enum ProConfig {
    static let server = ""     // the Worker, e.g. "https://pitch-shift-pro.NAME.workers.dev" (server/README.md)
    static let publicKey = ""  // base64 of the 32-byte Ed25519 public key (server/scripts/make-keys.mjs prints it)
    static let buyURL = ""     // the Stripe Payment Link, e.g. "https://buy.stripe.com/…"
    static let price = "$5"
    static let recheckDays = 0  // ask the server every N days whether the key was turned off (0 = never)
}
