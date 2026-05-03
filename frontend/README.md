# frontend — Railway service

Public face of the Premium LLM Gateway. Three jobs:

1. **Admin UI** at `/` — sign in with `ADMIN_PASSWORD`, generate LiteLLM
   virtual keys, watch spend per key, smoke-test the gateway.
2. **OpenAI-compatible passthrough** at `/v1/*` — what Cursor / Zed /
   Aider / any OpenAI client connects to. Streams transparently.
3. **Health probe** at `/healthz` — `200 ok` for Railway's load balancer.

The frontend never holds any model API keys — it only ever holds the
LiteLLM master key (used to mint virtual keys via the admin API). The
real model keys live on RunPod with LiteLLM.

## Local dev

```bash
cd frontend
cp .env.example .env
$EDITOR .env                      # set LITELLM_URL, LITELLM_MASTER_KEY, ADMIN_PASSWORD
npm install
npm run dev                       # tsx watch — restarts on save
open http://localhost:3000
```

## Deploy to Railway

1. Push this repo to GitHub (`git@github.com:jonathanbodnar/unlimited.git`).
2. In Railway: **New Project → Deploy from GitHub repo → Pick `unlimited`**.
3. **Service settings → Root Directory** = `frontend`.
   (Railway will then read `railway.json` and `package.json` from this folder.)
4. **Variables → add**:
   - `LITELLM_URL` = the RunPod public URL for port 4000
     (e.g. `https://pbm6glpnsw58mc-4000.proxy.runpod.net`)
   - `LITELLM_MASTER_KEY` = same value as on RunPod's `.env`
   - `ADMIN_PASSWORD` = strong passphrase you'll use to sign in
   - `SESSION_SECRET` = `openssl rand -hex 32`
5. **Settings → Networking → Generate Domain** → you get
   `https://<service>.up.railway.app`. That URL is what Jonathan puts in
   Cursor as `https://<service>.up.railway.app/v1`.

A custom domain (`api.yourdomain.com`) can be added later under
**Settings → Networking → Custom Domain**; nothing in this app cares.

## Architecture

```text
Cursor / IDE
    │  Authorization: Bearer sk-<virtual-key>
    ▼
Railway service (this app)
    ├── /            → server-rendered admin UI
    ├── /api/*       → admin endpoints, session-cookie auth
    └── /v1/*        → streaming reverse proxy (Bearer token forwarded)
              │
              ▼
RunPod LiteLLM (LITELLM_URL)
    ├── /key/generate, /global/spend/keys, /v1/chat/completions, …
    └── routes to MiMo / DeepSeek / Anthropic
```

## Why a session cookie and not OAuth?

Single-admin, low-traffic. HMAC-signed cookie keyed off `SESSION_SECRET`
is one file of code, no DB, no third-party auth. If we add a second admin
later, swap to e.g. Clerk or Lucia and rip out `src/auth.ts`.

## Why server-rendered HTML?

Two routes, three forms. Adding React/Next adds a build step, deploy
artifacts, and ten more dependencies. Every interaction here is a single
`fetch()` against a JSON endpoint we own — vanilla JS is faster to
deploy and easier to audit.

## Troubleshooting

- **"FATAL: LITELLM_URL is not set"** — set it in Railway Variables.
- **Health pill stays `unreachable`** — the RunPod pod is asleep or the
  `LITELLM_URL` is wrong. SSH in and `docker compose ps`.
- **/v1 returns 502 gateway upstream error** — same as above.
- **Logout doesn't stick** — `SESSION_SECRET` was rotated. Set it
  explicitly in Railway Variables so deploys don't invalidate cookies.
- **Streaming responses arrive in one chunk** — make sure the client is
  sending `"stream": true` in the request body. The proxy itself does
  not buffer.
