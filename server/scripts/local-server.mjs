// A local stand-in for the Worker, for testing the Mac app without Cloudflare or Stripe (keys kept in memory).
//   node scripts/make-keys.mjs --json > /tmp/test-secrets.json
//   node scripts/local-server.mjs /tmp/test-secrets.json [--port 8787] [--seed cs_test_one,cs_live_two]
// --seed makes keys as if those Checkout Sessions had been paid, and prints them. Test keys only: never point it
// at real secrets.
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import worker, { fulfill } from "../src/index.js";
import { MemoryKV } from "../test/memory-kv.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const secrets = JSON.parse(readFileSync(args[0], "utf8"));
const env = { PRO: new MemoryKV(), KEY_SECRET: secrets.KEY_SECRET, SIGNING_KEY: secrets.SIGNING_KEY, ALLOW_TEST_KEYS: "true" };
const port = Number(option("--port", "8787"));

for (const id of option("--seed", "").split(",").filter(Boolean)) {
  const entry = await fulfill(env, {
    id, object: "checkout.session", status: "complete", payment_status: "paid", livemode: id.startsWith("cs_live_"),
    customer_details: { email: "test@example.com" }, payment_intent: `pi_${id}`,
  });
  console.log(`key for ${id}: ${entry.key}`);
}
if (args.includes("--revoke-first")) {
  const [first] = [...env.PRO.data.keys()].filter((k) => k.startsWith("key:"));
  const entry = JSON.parse(env.PRO.data.get(first));
  env.PRO.data.set(first, JSON.stringify({ ...entry, revoked: true }));
  console.log(`turned off ${entry.key}`);
}

createServer(async (incoming, outgoing) => {
  const chunks = [];
  for await (const chunk of incoming) chunks.push(chunk);
  const body = chunks.length ? Buffer.concat(chunks) : undefined;
  const request = new Request(`http://127.0.0.1:${port}${incoming.url}`, {
    method: incoming.method, headers: incoming.headers, body: incoming.method === "GET" ? undefined : body,
  });
  const response = await worker.fetch(request, env);
  outgoing.writeHead(response.status, Object.fromEntries(response.headers));
  outgoing.end(Buffer.from(await response.arrayBuffer()));
  console.log(`${incoming.method} ${incoming.url} → ${response.status}`);
}).listen(port, "127.0.0.1", () => console.log(`listening on http://127.0.0.1:${port}`));
