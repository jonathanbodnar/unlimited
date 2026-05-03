# premium-llm-gateway

The **RunPod** half of the gateway: LiteLLM proxy + Postgres in Docker
Compose. The **Railway frontend** that fronts this lives at `../frontend/`
and is what users actually point Cursor at — see the top-level
`../README.md` for the end-to-end flow.

Phase 1 measures one thing:

> If we provide a Claude-like coding experience using hosted premium
> models, what does one heavy premium developer actually cost us per
> day/month?

No GPU hosting, no self-hosted models, no RAG. We measure first.

## Architecture (Phase 1)

```text
Cursor / IDE / OpenAI client
        │
        ▼
LiteLLM Proxy (this repo)         ← OpenAI-compatible /v1
        │  - virtual user keys
        │  - routing & fallbacks
        │  - budgets / spend tracking
        │  - Langfuse callbacks
        ▼
Hosted models                     ← MiMo-V2.5-Pro, DeepSeek V4 Pro/Flash,
                                    Claude (benchmark only)
        │
        ▼
Postgres (LiteLLM) + Langfuse Cloud (traces / quality)
```

The user only ever sees `dev-auto`. The gateway picks the real backend.

## Repo layout

```text
premium-llm-gateway/
  docker-compose.yml             # Postgres + LiteLLM
  .env.example                   # secrets template
  litellm_config.yaml            # default = MODE A (premium-heavy)
  litellm_config_modes/
    mode_a_premium_heavy.yaml
    mode_b_balanced.yaml
    mode_c_aggressive_margin.yaml
  scripts/
    generate_key.sh              # mint a virtual key for a test user
    healthcheck.sh               # liveliness + readiness + real completion
    daily_report.py              # daily cost / quality summary
  docs/
    cursor_setup.md
    routing_modes.md
    metrics.md
  reports/                       # daily JSON + Markdown reports (git-ignored)
```

## Prerequisites

- Cheap CPU host: 2–4 vCPU, 8–16 GB RAM, 100 GB disk, public HTTPS.
  (Render / Railway / Fly.io / Hetzner / DigitalOcean / Lightsail / RunPod CPU.)
- Docker + Docker Compose.
- An admin you trust holds the **master key**; users only ever get virtual keys.
- API keys collected up front:

  ```text
  MIMO_API_KEY
  DEEPSEEK_API_KEY
  ANTHROPIC_API_KEY     (optional, benchmark only)
  OPENAI_API_KEY        (optional)
  LANGFUSE_PUBLIC_KEY
  LANGFUSE_SECRET_KEY
  ```

- Provider details to confirm before first run:
  1. Exact MiMo-V2.5-Pro OpenAI-compatible base URL
  2. Exact MiMo-V2.5-Pro model name
  3. Exact DeepSeek V4 Pro OpenAI-compatible base URL
  4. Exact DeepSeek V4 Pro model name
  5. Exact DeepSeek V4 Flash model name

  These get pasted into `litellm_config.yaml` (and the per-mode files in
  `litellm_config_modes/`) wherever you see `REPLACE_WITH_…`.

## 5-minute boot on a RunPod pod

```bash
# SSH in, then:
cd /workspace
git clone https://github.com/jonathanbodnar/unlimited.git
cd unlimited/premium-llm-gateway

# One-shot bootstrap. Pass provider keys via env. .env will be created
# with sane defaults (random POSTGRES_PASSWORD, random LITELLM_MASTER_KEY).
MIMO_API_KEY=...        \
DEEPSEEK_API_KEY=...    \
LANGFUSE_PUBLIC_KEY=... \
LANGFUSE_SECRET_KEY=... \
ANTHROPIC_API_KEY=...   \
./scripts/bootstrap_runpod.sh

# Now expose the pod's port 4000 from the RunPod UI:
#   pod → Edit → HTTP Service Ports = 4000
# That gives you a public URL like:
#   https://<pod-id>-4000.proxy.runpod.net
```

Use that URL as `LITELLM_URL` in the Railway service. Users then point
Cursor at the **Railway** domain (`https://<railway>/v1`), not RunPod.

The whole user-facing surface stays the same:

```text
API Base URL:  https://<your-railway-domain>/v1
API Key:       sk-…                            (minted from the Railway UI)
Model:         dev-auto
```

For local dev (no RunPod), the same `docker compose up -d` works:

```bash
cp .env.example .env
$EDITOR .env
$EDITOR litellm_config.yaml                 # fill REPLACE_WITH_… placeholders
docker compose up -d
docker compose logs -f litellm
curl http://localhost:4000/health
```

## Public hostname

In our deployment, **Railway** is the public face — it handles HTTPS and
domain. RunPod stays internal-ish; the only public exposure on RunPod is
its own `https://<pod-id>-4000.proxy.runpod.net` URL, which is what
Railway's `LITELLM_URL` points at.

If you ever run this without Railway (e.g. a Hetzner box for production),
put Caddy in front:

```caddy
api.yourdomain.com {
  reverse_proxy localhost:4000
}
```

## Test modes

We measure three routing strategies, **3–5 real workdays each**, with
Jonathan rating quality at 1–5 per session. Full details in
`docs/routing_modes.md`.

| Mode |        Default for `dev-auto`       | Purpose                                |
| :--: | :---------------------------------: | -------------------------------------- |
|  A   |             MiMo-V2.5-Pro           | premium-heavy → worst-case cost        |
|  B   | MiMo-Pro (Flash before Pro on fail) | balanced → likely product economics    |
|  C   |              DS-V4-Flash            | aggressive margin → quality floor test |

Switching is a symlink + restart:

```bash
ln -sf litellm_config_modes/mode_b_balanced.yaml litellm_config.yaml
docker compose restart litellm
sed -i.bak 's/^ACTIVE_MODE=.*/ACTIVE_MODE=B/' .env && rm .env.bak
./scripts/healthcheck.sh
```

## Daily ritual

At end of each workday:

```bash
./scripts/daily_report.py --hours 4.2 --quality 4.5 \
  --notes "Great for architecture, slightly slower in autocomplete." \
  --json
```

That writes `reports/YYYY-MM-DD.json` and `reports/YYYY-MM-DD.md` and
prints the spec's exact summary format. Commit those (or sync them
somewhere) so you can see trend lines after a couple of weeks.

See `docs/metrics.md` for what each number means and which pricing tier
is implied by each monthly-cost band.

## First 7-day plan

| Day | What                                                            |
| --- | --------------------------------------------------------------- |
|  0  | Deploy stack, generate Jonathan's key, connect Cursor, smoke    |
|  1–3| **Mode A** premium-heavy — measure worst-case cost              |
|  4–6| **Mode B** balanced — measure likely product economics          |
|  7  | Compare A vs B vs Claude rescue rate vs quality. Decide:         |
|     |   - Mode B 4+/5 quality and projected <$250/mo  → product MVP    |
|     |   - Mode B between $250–$500/mo                 → optimize / GPU |
|     |   - Mode B >$500/mo                             → hosted-only is unviable |

## Acceptance criteria (Phase 1)

The setup is done when:

1. LiteLLM is reachable at `/v1` over HTTPS.
2. Cursor uses `dev-auto` through a virtual key (not the master key).
3. Requests route to MiMo / DeepSeek hosted models.
4. Fallbacks fire on provider failure or context overflow.
5. Token usage and cost are visible per user / per key (LiteLLM admin UI + DB).
6. Langfuse traces show model, latency, tokens, errors.
7. Mode A, Mode B, and Mode C can each run by swapping the config.
8. `scripts/daily_report.py` produces the spec's daily summary.

## Important non-goals (Phase 1)

- **No vLLM, no GPU, no local models.** Phase 2.
- **No RAG.** Phase 2.
- **No throttling for Jonathan.** We want full cost weight first.
- **No multi-model exposure to users.** One endpoint, one key, one model name.

## Phase 2 (later)

- Add a thin gateway in front of LiteLLM that classifies prompts as
  `simple | normal | hard` and maps them to backend aliases. This is what
  enables a "real" Mode B.
- Introduce vLLM / SGLang with Qwen Coder, DeepSeek Coder, or a smaller
  local MiMo to absorb 60–80 % of simple traffic.
- Add Qdrant + code-aware chunking + embeddings for RAG.
- Add fair-use controls (gentle: shorter responses, more Flash routing —
  never "you are out of tokens").

## Pricing hypotheses to validate

We are testing whether the economics support these tiers:

```text
$199 / mo  Pro
$299 / mo  Power
$499 / mo  Ultra
$999 / mo  Agency / Priority
```

If Jonathan costs >$300/mo in Mode B, **do not** offer $199 true-unlimited.
Use language like "no token anxiety", "generous premium usage",
"fair-use based", "priority coding intelligence". Avoid promising
mathematically unlimited usage with no controls.
