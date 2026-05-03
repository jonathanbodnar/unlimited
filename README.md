# unlimited

Hosted-model LLM gateway for measuring the **true cost** of one heavy
premium developer.

> If we provide a Claude-like coding experience using hosted premium
> models, what does one heavy premium developer actually cost us per
> day/month?

## Architecture

Two services, two clouds:

```text
Cursor / IDE / OpenAI client
        │
        │  https://<your-railway-domain>/v1
        ▼
┌──────────────────────────────────┐
│ Railway service  (this/frontend) │   public face — UI + /v1 streaming proxy
│  - admin login                   │
│  - generate virtual keys         │
│  - watch spend per key           │
│  - smoke-test                    │
│  - /v1/* → upstream              │
└────────────┬─────────────────────┘
             │  https://<pod-id>-4000.proxy.runpod.net
             ▼
┌──────────────────────────────────┐
│ RunPod pod  (premium-llm-gateway) │   real gateway, runs in Docker
│  - LiteLLM proxy (port 4000)     │
│  - Postgres (spend/keys store)   │
│  - Langfuse callbacks             │
└────────────┬─────────────────────┘
             ▼
   MiMo-V2.5-Pro · DeepSeek V4 Pro · DeepSeek V4 Flash · Claude (benchmark)
```

The user only ever sees the Railway domain and the model name `dev-auto`.
Routing to MiMo / DeepSeek / Claude is decided server-side by whichever
LiteLLM config is mounted into the RunPod container (see
`premium-llm-gateway/docs/routing_modes.md`).

## Repo layout

```text
unlimited/
  README.md                       (this file)
  frontend/                       Railway service: UI + /v1 proxy
    src/server.ts
    src/auth.ts
    src/pages.ts
    package.json, Dockerfile, railway.json, .env.example
  premium-llm-gateway/            RunPod stack: LiteLLM + Postgres
    docker-compose.yml
    litellm_config.yaml           default = MODE A (premium-heavy)
    litellm_config_modes/         A / B / C variants
    scripts/
      bootstrap_runpod.sh         one-shot setup on a RunPod pod
      generate_key.sh             CLI key minting (also exposed via UI)
      healthcheck.sh
      daily_report.py
    docs/
      cursor_setup.md
      routing_modes.md
      metrics.md
```

## End-to-end flow

| #  | What                                                                         | Where         |
| -- | ---------------------------------------------------------------------------- | ------------- |
|  1 | Start the RunPod pod and SSH in                                              | RunPod UI     |
|  2 | Run `bootstrap_runpod.sh` with provider keys → LiteLLM up on `:4000`         | RunPod pod    |
|  3 | Edit pod → add HTTP Service Port `4000` → get `https://<pod>-4000.proxy.runpod.net` | RunPod UI     |
|  4 | Push this repo to GitHub                                                     | local         |
|  5 | New Railway project from this repo, **Root Directory = `frontend`**          | Railway       |
|  6 | Set `LITELLM_URL`, `LITELLM_MASTER_KEY`, `ADMIN_PASSWORD`, `SESSION_SECRET`   | Railway vars  |
|  7 | Generate Railway domain → that's the public `/v1`                            | Railway       |
|  8 | Open `https://<railway>/`, sign in, click **Generate key** → copy the `sk-…` | Railway UI    |
|  9 | In Cursor: base URL = `https://<railway>/v1`, key = the `sk-…`, model = `dev-auto` | Cursor        |
| 10 | Use Cursor normally; check `/dashboard` for spend; run `daily_report.py`     | both          |

## Quick reference

### What goes into Railway Variables

```text
LITELLM_URL          https://<pod-id>-4000.proxy.runpod.net
LITELLM_MASTER_KEY   sk-admin-…                          (same as on RunPod)
ADMIN_PASSWORD       <your strong passphrase>            (UI sign-in)
SESSION_SECRET       <openssl rand -hex 32>              (cookie signing)
```

### What goes into RunPod's `premium-llm-gateway/.env`

```text
POSTGRES_PASSWORD    <random>
LITELLM_MASTER_KEY   sk-admin-…                          (random, share with Railway)

MIMO_API_KEY         <provider key>
DEEPSEEK_API_KEY     <provider key>
ANTHROPIC_API_KEY    <optional, for Claude benchmark>
OPENAI_API_KEY       <optional>

LANGFUSE_PUBLIC_KEY  pk-lf-…
LANGFUSE_SECRET_KEY  sk-lf-…
LANGFUSE_HOST        https://cloud.langfuse.com
```

`bootstrap_runpod.sh` will accept these via env vars and write them to
`.env` for you.

### What goes into Cursor

```text
Base URL:  https://<your-railway-domain>/v1
API Key:   sk-…    (from Railway UI → "Generate key")
Model:     dev-auto
```

## Test modes (3–5 workdays each)

| Mode | Default backend  | Cascade on failure                            | Goal                          |
| :--: | ---------------- | --------------------------------------------- | ----------------------------- |
|  A   | MiMo-V2.5-Pro    | DS-V4-Pro → DS-V4-Flash → Claude (benchmark)  | worst-case premium cost       |
|  B   | MiMo-V2.5-Pro    | DS-V4-Flash → DS-V4-Pro                       | likely product economics      |
|  C   | DS-V4-Flash      | MiMo-V2.5-Pro → DS-V4-Pro                     | quality floor / cheapest mix  |

Switching: SSH into RunPod, symlink the desired
`litellm_config_modes/mode_*.yaml` over `litellm_config.yaml`,
`docker compose restart litellm`. Full instructions in
`premium-llm-gateway/docs/routing_modes.md`.

## Daily ritual

End of each workday, on RunPod (or anywhere with admin key + URL):

```bash
cd /workspace/unlimited/premium-llm-gateway
./scripts/daily_report.py --hours 4.2 --quality 4.5 \
  --notes "Great for architecture, slow in autocomplete." --json
```

Writes `reports/YYYY-MM-DD.json` and `reports/YYYY-MM-DD.md`. After
10–15 workdays, compare modes and decide on a pricing tier
(see `premium-llm-gateway/docs/metrics.md`).

## Security model

- **Master key** lives in two places (RunPod `.env` and Railway
  Variables) and **nowhere else**. Never in Cursor, never in chat, never
  committed.
- **Virtual keys** are minted via the Railway UI, scoped per user and
  budget, time-limited, and bound to specific model aliases.
- **Admin UI** is protected by a single `ADMIN_PASSWORD` + HMAC-signed
  cookie. Anyone with the password can mint virtual keys.
- **`/v1/*`** carries whatever Bearer token the client sends; the
  Railway service does not inspect or rewrite it.

## Phase 2 (later, not now)

- Thin classification gateway in front of LiteLLM (real Mode B routing).
- vLLM / SGLang on a GPU pod (Qwen Coder, DeepSeek Coder, smaller MiMo)
  to absorb 60–80 % of simple traffic.
- Qdrant + code-aware chunking + embeddings for RAG.
- Fair-use controls (gentle: shorter responses, more Flash routing —
  never "you are out of tokens").
