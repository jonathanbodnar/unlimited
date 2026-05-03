# Routing modes

The gateway exposes exactly one user-facing model: **`dev-auto`**.
All real routing decisions are made server-side by LiteLLM, controlled by
which config file is mounted into the `litellm` container.

| File                                              | Mode | Default backend  | Cascade on failure                            |
| ------------------------------------------------- | :--: | ---------------- | --------------------------------------------- |
| `litellm_config_modes/mode_a_premium_heavy.yaml`  |  A   | MiMo-V2.5-Pro    | DS-V4-Pro → DS-V4-Flash → Claude (benchmark)  |
| `litellm_config_modes/mode_b_balanced.yaml`       |  B   | MiMo-V2.5-Pro    | DS-V4-Flash → DS-V4-Pro                       |
| `litellm_config_modes/mode_c_aggressive_margin.yaml` | C | DS-V4-Flash      | MiMo-V2.5-Pro → DS-V4-Pro                     |

The default `litellm_config.yaml` at the repo root is a copy of Mode A so
the first test boots in worst-case-cost mode without any extra steps.

## Mode A — Premium-Heavy / Worst-Case Cost

> **Question:** what does it cost if the user gets a premium experience
> almost every time?

`dev-auto` resolves to MiMo-Pro. Failures cascade to DS-V4-Pro before any
cheaper option, which makes this the most expensive but highest-quality
configuration. Run it for **3–5 real workdays** to anchor the upper bound.

Expected output:

- highest cost
- best quality
- the most honest premium-user cost baseline

## Mode B — Balanced / Likely Product Mode

> **Question:** what does the product probably cost if it feels premium but
> still protects margin?

The spec calls for "simple → Flash, normal → MiMo, hard → DS-V4-Pro", which
needs a complexity classifier in front of LiteLLM. We are **not** building
that classifier in Phase 1.

Mode B's pure-config approximation:

- `dev-auto` still defaults to MiMo-Pro (the "normal" path).
- On failure or context overflow, the cascade goes `Flash → DS-V4-Pro`
  (cheap before expensive), so any blip pushes traffic to the cheaper Flash
  rather than another premium model.

This is the closest approximation we can express in pure LiteLLM config,
and it gives a useful upper bound on the real Mode B cost. When the thin
classification gateway is built later, point its "simple" verdict at
`deepseek-v4-flash` directly and leave this config in place.

Run for **3–5 real workdays**. Expected output:

- realistic product cost
- quality score vs Mode A
- fallback percentage

## Mode C — Aggressive Margin

> **Question:** how cheap can we go before quality breaks?

`dev-auto` resolves to DS-V4-Flash. Premium retries go to MiMo-Pro, hard
retries to DS-V4-Pro. Long-context prompts skip Flash entirely via
`context_window_fallbacks`.

Run for **3–5 real workdays**. Expected output:

- lowest cost
- quality degradation threshold
- estimate of minimum viable infrastructure cost

## Switching modes

Symlink the desired mode file over `litellm_config.yaml` and restart the
container:

```bash
cd premium-llm-gateway

# pick one
ln -sf litellm_config_modes/mode_a_premium_heavy.yaml      litellm_config.yaml
ln -sf litellm_config_modes/mode_b_balanced.yaml           litellm_config.yaml
ln -sf litellm_config_modes/mode_c_aggressive_margin.yaml  litellm_config.yaml

docker compose restart litellm
./scripts/healthcheck.sh
```

Update `ACTIVE_MODE` in `.env` so daily reports are tagged correctly:

```bash
sed -i.bak 's/^ACTIVE_MODE=.*/ACTIVE_MODE=B/' .env && rm .env.bak
```

## What stays the same across modes

- The user-facing model name is always `dev-auto`.
- Virtual API keys, budgets, and Langfuse callbacks are unaffected.
- Cost tracking is per-call regardless of which backend served the call,
  so the daily report works identically across modes.

## Phase-2 (later)

When we add the thin gateway service in front of LiteLLM, it will:

1. Classify each prompt as `simple | normal | hard` using a small local
   model or rules.
2. Map the verdict to a backend alias (`deepseek-v4-flash`, `mimo-pro`,
   `deepseek-v4-pro`) and pass that alias to LiteLLM.
3. Keep `dev-auto` as the single user-facing name; users still see one
   endpoint, one key, one model.

That work is intentionally **out of scope** for the cost-measurement phase.
