// webhook.ts — Minimal GitHub webhook listener for Poseidon auto-updates
// Deployed to /opt/poseidon-webhook/webhook.ts on the droplet.
// Runs under systemd; reads config from environment variables.

const PORT = Number(process.env.WEBHOOK_PORT) || 18792;
const SECRET = process.env.WEBHOOK_SECRET || "";
const BRANCH = process.env.POSEIDON_BRANCH || "main";

async function verifySignature(
  payload: string,
  signature: string | null,
): Promise<boolean> {
  if (!SECRET || !signature) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(payload),
  );
  const expected =
    "sha256=" +
    Array.from(new Uint8Array(sig))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  return signature === expected;
}

Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);

    if (req.method !== "POST" || url.pathname !== "/webhook") {
      return new Response("Not found", { status: 404 });
    }

    const body = await req.text();
    const signature = req.headers.get("x-hub-signature-256");

    if (!(await verifySignature(body, signature))) {
      return new Response("Unauthorized", { status: 401 });
    }

    // Only handle push events
    const event = req.headers.get("x-github-event");
    if (event !== "push") {
      return new Response("Ignored event: " + event, { status: 200 });
    }

    // Only handle pushes to the configured branch
    try {
      const payload = JSON.parse(body);
      const ref = payload.ref || "";
      if (ref !== `refs/heads/${BRANCH}`) {
        return new Response("Ignored branch: " + ref, { status: 200 });
      }
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    // Spawn update script async — return immediately
    Bun.spawn(["bash", "/opt/poseidon-webhook/update.sh"], {
      stdout: "inherit",
      stderr: "inherit",
    });

    return new Response("Build triggered", { status: 200 });
  },
});

console.log(`Webhook listener running on port ${PORT}`);
