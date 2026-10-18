// The signed token the app keeps: "PAYLOAD.SIGNATURE", both base64url. PAYLOAD is JSON, SIGNATURE is Ed25519 over the
// PAYLOAD text exactly as sent. The app checks it offline with the public key built into it (Sources/ProConfig.swift).
const encoder = new TextEncoder();

export function base64url(bytes) {
  let text = "";
  for (const byte of new Uint8Array(bytes)) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64(text) {
  const clean = String(text).replace(/-/g, "+").replace(/_/g, "/").replace(/\s/g, "");
  const binary = atob(clean + "=".repeat((4 - (clean.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

let cached = { secret: null, key: null };

// SIGNING_KEY: the Ed25519 private key as base64 PKCS#8 (scripts/make-keys.mjs makes it).
async function signingKey(secret) {
  if (!secret) throw new Error("SIGNING_KEY is not set");
  if (cached.secret !== secret) {
    cached = { secret, key: await crypto.subtle.importKey("pkcs8", fromBase64(secret), { name: "Ed25519" }, false, ["sign"]) };
  }
  return cached.key;
}

// payload: { v: 1, p: "pitch-shift-pro", k: key id, m: Mac id, t: seconds since 1970, x: "live" | "test" }
export async function signToken(secret, payload) {
  const body = base64url(encoder.encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, await signingKey(secret), encoder.encode(body));
  return `${body}.${base64url(signature)}`;
}
