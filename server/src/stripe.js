// Stripe: checking that a webhook message really comes from Stripe, and reading a Checkout Session.
const encoder = new TextEncoder();

function hex(bytes) {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Same-time comparison of two strings (so the time taken doesn't tell how much of a signature matched).
export function sameText(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// The Stripe-Signature header is "t=TIME,v1=SIGNATURE[,v1=…]". The signature is HMAC-SHA-256 of "TIME.BODY" with the
// webhook's signing secret (whsec_…). Messages older than `tolerance` seconds are refused (no replays).
export async function verifyStripeSignature(rawBody, header, secret, now = Math.floor(Date.now() / 1000), tolerance = 300) {
  if (!secret || !header) return false;
  let time = null;
  const signatures = [];
  for (const part of header.split(",")) {
    const [name, value] = part.split("=", 2).map((s) => s?.trim());
    if (name === "t") time = value;
    else if (name === "v1" && value) signatures.push(value);
  }
  if (!time || !/^\d+$/.test(time) || signatures.length === 0) return false;
  if (Math.abs(now - Number(time)) > tolerance) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = hex(await crypto.subtle.sign("HMAC", key, encoder.encode(`${time}.${rawBody}`)));
  return signatures.some((signature) => sameText(signature, expected));
}

// GET from Stripe's API with the restricted key. Returns the object, or null when Stripe says it doesn't exist.
export async function stripeGet(env, path) {
  if (!env.STRIPE_SECRET_KEY) throw new Error("STRIPE_SECRET_KEY is not set");
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}` },
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Stripe answered ${response.status}`);
  return response.json();
}

// A Checkout Session that should get a key: finished, paid, and (when STRIPE_PAYMENT_LINK is set) from that link.
export function sessionCounts(env, session) {
  if (!session || session.object !== "checkout.session") return false;
  if (session.status !== "complete" || session.payment_status !== "paid") return false;
  if (env.STRIPE_PAYMENT_LINK && session.payment_link !== env.STRIPE_PAYMENT_LINK) return false;
  return true;
}
