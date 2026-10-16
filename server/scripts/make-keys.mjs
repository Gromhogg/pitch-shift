// Makes the two secrets the server makes itself, and gives the app its public key.
//   node scripts/make-keys.mjs --put    makes SIGNING_KEY (Ed25519) and KEY_SECRET, stores both on Cloudflare with
//                                       "npx wrangler secret put" (nothing is written to a file), and prints the
//                                       public key to put in the app (Sources/ProConfig.swift, publicKey).
//   node scripts/make-keys.mjs --show   the same, and also prints both secrets once, to save in your Passwords app.
//   node scripts/make-keys.mjs --json   prints everything as JSON (for local tests only; never for the real server).
// Run it once. Running it again makes NEW secrets: KEY_SECRET must never change once keys are sold, and a new
// SIGNING_KEY needs a new app build with the new public key.
import { spawnSync } from "node:child_process";

const args = process.argv.slice(2);
const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const b64 = (bytes) => Buffer.from(bytes).toString("base64");
const secrets = {
  SIGNING_KEY: b64(await crypto.subtle.exportKey("pkcs8", pair.privateKey)),
  KEY_SECRET: b64(crypto.getRandomValues(new Uint8Array(32))),
};
const publicKey = b64(await crypto.subtle.exportKey("raw", pair.publicKey));

if (args.includes("--json")) {
  console.log(JSON.stringify({ ...secrets, PUBLIC_KEY: publicKey }, null, 2));
  process.exit(0);
}
if (!args.includes("--put") && !args.includes("--show")) {
  console.log("Use --put (store the secrets on Cloudflare) or --show (also print them). Nothing was made.");
  process.exit(1);
}
for (const [name, value] of Object.entries(secrets)) {
  const result = spawnSync("npx", ["wrangler", "secret", "put", name], { input: value + "\n", stdio: ["pipe", "inherit", "inherit"] });
  if (result.status !== 0) {
    console.log(`Could not store ${name}. Run "npx wrangler login" first, then run this again.`);
    process.exit(1);
  }
}
console.log(`\nPublic key for the app (Sources/ProConfig.swift, publicKey; not a secret):\n${publicKey}\n`);
if (args.includes("--show")) {
  console.log("Secrets (save them in your Passwords app, then clear this window):");
  for (const [name, value] of Object.entries(secrets)) console.log(`${name}=${value}`);
}
