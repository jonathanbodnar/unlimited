import { serve } from "@hono/node-server";
import { Hono } from "hono";
import {
  checkAdminPassword,
  clearSessionCookie,
  isAuthenticated,
  setSessionCookie,
} from "./auth.js";
import { dashboardPage, loginPage } from "./pages.js";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT = Number(process.env.PORT || 3000);

const LITELLM_URL = (process.env.LITELLM_URL || "").replace(/\/+$/, "");
const LITELLM_MASTER_KEY = process.env.LITELLM_MASTER_KEY || "";

if (!LITELLM_URL) {
  console.error("FATAL: LITELLM_URL is not set.");
  process.exit(1);
}
if (!LITELLM_MASTER_KEY || LITELLM_MASTER_KEY === "sk-admin-replace-me") {
  console.error(
    "FATAL: LITELLM_MASTER_KEY is unset or still the placeholder.",
  );
  process.exit(1);
}
if (!process.env.ADMIN_PASSWORD) {
  console.error("FATAL: ADMIN_PASSWORD is not set.");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

const app = new Hono();

// Tiny request log so Railway logs are useful.
app.use("*", async (c, next) => {
  const t0 = Date.now();
  await next();
  const ms = Date.now() - t0;
  const ip =
    c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ||
    c.req.header("x-real-ip") ||
    "-";
  console.log(
    `${c.req.method} ${c.req.path} ${c.res.status} ${ms}ms ip=${ip}`,
  );
});

// ---------------------------------------------------------------------------
// Auth pages
// ---------------------------------------------------------------------------

app.get("/", (c) =>
  c.redirect(isAuthenticated(c) ? "/dashboard" : "/login"),
);

app.get("/login", (c) => c.html(loginPage()));

app.post("/login", async (c) => {
  const body = await c.req.parseBody();
  const password = String(body.password || "");
  if (!checkAdminPassword(password)) {
    return c.html(loginPage("Wrong password"));
  }
  setSessionCookie(c);
  return c.redirect("/dashboard");
});

app.post("/logout", (c) => {
  clearSessionCookie(c);
  return c.redirect("/login");
});

app.get("/dashboard", (c) => {
  if (!isAuthenticated(c)) return c.redirect("/login");
  // Build a friendly base host for the "give to Cursor" snippet.
  const proto =
    c.req.header("x-forwarded-proto") ||
    new URL(c.req.url).protocol.replace(":", "");
  const host = c.req.header("host") || "localhost:" + PORT;
  const baseHost = `${proto}://${host}`;
  return c.html(dashboardPage({ litellmUrl: LITELLM_URL, baseHost }));
});

// ---------------------------------------------------------------------------
// Admin API — protected by session cookie
// ---------------------------------------------------------------------------

app.use("/api/*", async (c, next) => {
  if (!isAuthenticated(c)) {
    return c.json({ error: { message: "unauthorized" } }, 401);
  }
  await next();
});

app.get("/api/health", async (c) => {
  try {
    const r = await fetch(`${LITELLM_URL}/health/liveliness`, {
      signal: AbortSignal.timeout(5000),
    });
    return c.json({ ok: r.ok, status: r.status, target: LITELLM_URL });
  } catch (e: any) {
    return c.json(
      { ok: false, error: e?.message || String(e), target: LITELLM_URL },
      502,
    );
  }
});

app.post("/api/keys", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const r = await fetch(`${LITELLM_URL}/key/generate`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${LITELLM_MASTER_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    json = { error: { message: text || `upstream returned ${r.status}` } };
  }
  return c.json(json as object, r.status as any);
});

// LiteLLM exposes spend/key listings in a few different shapes depending on
// version. Try the modern endpoint first, then fall back.
app.get("/api/keys", async (c) => {
  const tries = [
    `${LITELLM_URL}/global/spend/keys?limit=200`,
    `${LITELLM_URL}/spend/keys?limit=200`,
    `${LITELLM_URL}/key/list?limit=200`,
  ];
  for (const url of tries) {
    try {
      const r = await fetch(url, {
        headers: { Authorization: `Bearer ${LITELLM_MASTER_KEY}` },
      });
      if (!r.ok) continue;
      const j = await r.json();
      return c.json({ keys: Array.isArray(j) ? j : j.keys || j.data || [] });
    } catch {
      continue;
    }
  }
  return c.json({ keys: [] });
});

app.post("/api/test", async (c) => {
  const {
    key,
    model = "dev-auto",
    prompt = 'reply with the single word: "pong"',
  } = await c.req.json().catch(() => ({}));
  if (!key || typeof key !== "string") {
    return c.json({ error: "missing virtual key" }, 400);
  }
  try {
    const r = await fetch(`${LITELLM_URL}/v1/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        messages: [{ role: "user", content: prompt }],
        max_tokens: 32,
        stream: false,
      }),
      signal: AbortSignal.timeout(60_000),
    });
    const text = await r.text();
    let data: unknown;
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
    return c.json({ status: r.status, data });
  } catch (e: any) {
    return c.json({ status: 0, error: e?.message || String(e) }, 502);
  }
});

// ---------------------------------------------------------------------------
// /v1 reverse proxy — public, streaming, OpenAI-compatible.
// Auth is whatever Bearer token the client sends; we forward it to LiteLLM.
// ---------------------------------------------------------------------------

const HOP_BY_HOP = new Set([
  "host",
  "content-length",
  "connection",
  "transfer-encoding",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "upgrade",
]);

app.all("/v1/*", async (c) => {
  const url = new URL(c.req.url);
  const upstream = `${LITELLM_URL}${url.pathname}${url.search}`;

  const headers = new Headers();
  c.req.raw.headers.forEach((v, k) => {
    if (!HOP_BY_HOP.has(k.toLowerCase())) headers.set(k, v);
  });

  const init: RequestInit & { duplex?: "half" } = {
    method: c.req.method,
    headers,
  };
  if (c.req.method !== "GET" && c.req.method !== "HEAD") {
    init.body = c.req.raw.body as any;
    init.duplex = "half"; // required for streaming Node fetch bodies
  }

  let upstreamResp: Response;
  try {
    upstreamResp = await fetch(upstream, init);
  } catch (e: any) {
    return c.json(
      {
        error: {
          message: `gateway upstream error: ${e?.message || e}`,
          type: "gateway_error",
        },
      },
      502,
    );
  }

  const respHeaders = new Headers();
  upstreamResp.headers.forEach((v, k) => {
    if (!HOP_BY_HOP.has(k.toLowerCase())) respHeaders.set(k, v);
  });
  return new Response(upstreamResp.body, {
    status: upstreamResp.status,
    statusText: upstreamResp.statusText,
    headers: respHeaders,
  });
});

// ---------------------------------------------------------------------------
// Top-level health (Railway / load balancer probes)
// ---------------------------------------------------------------------------

app.get("/healthz", (c) => c.text("ok"));

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

serve(
  { fetch: app.fetch, port: PORT },
  (info) => {
    console.log(
      `[gateway-frontend] listening on :${info.port} -> upstream ${LITELLM_URL}`,
    );
  },
);
