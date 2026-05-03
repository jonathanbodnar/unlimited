# Cursor / IDE setup

This is the only configuration Jonathan (or any test user) needs in their IDE.
The gateway is fully OpenAI-compatible, so the same setup works in Cursor,
Zed, Continue.dev, Aider, Cline, and any HTTP client that speaks the OpenAI
chat-completions API.

## What you need

The operator gives you three values (in our deployment they come from
the Railway service, not directly from RunPod):

```text
API Base URL:  https://<your-railway-domain>/v1
API Key:       sk-…                              # virtual key from the Railway UI
Model:         dev-auto
```

Never use the LiteLLM master key (`sk-admin-…`) here. It can mint other keys
and is meant only for the Railway service / `scripts/generate_key.sh` admin.

## Cursor

1. Open Cursor → **Settings** → **Models**.
2. Scroll to **OpenAI API Key** and click **Override OpenAI Base URL**.
3. Set:
   - **Base URL**: `https://<your-railway-domain>/v1`
   - **API Key**: the virtual key from the Railway UI
4. Under **Model Names**, add a custom model: `dev-auto`.
5. Click **Verify** — Cursor will hit `/v1/models` against the gateway.
6. Set `dev-auto` as your active model in the chat / Cmd-K UI.

You only ever pick `dev-auto`. The gateway decides which backend
(MiMo / DeepSeek Pro / DeepSeek Flash / Claude) actually serves the request,
based on the active routing mode (see `docs/routing_modes.md`).

### Verifying it works

In Cursor's chat, ask: `say "pong"`. You should get a one-word reply.
Then on the server run `./scripts/healthcheck.sh` to confirm the request
round-tripped through LiteLLM.

## Zed

`~/.config/zed/settings.json`:

```json
{
  "language_models": {
    "openai": {
      "api_url": "https://<your-railway-domain>/v1",
      "available_models": [
        { "name": "dev-auto", "max_tokens": 200000 }
      ]
    }
  }
}
```

Set the API key via `cmd-shift-p` → `zed: open keymap` → `Assistant: API Key`.

## Continue.dev

`~/.continue/config.json`:

```json
{
  "models": [
    {
      "title": "dev-auto",
      "provider": "openai",
      "model": "dev-auto",
      "apiBase": "https://<your-railway-domain>/v1",
      "apiKey": "sk-..."
    }
  ]
}
```

## Aider / generic OpenAI clients

```bash
export OPENAI_API_BASE=https://<your-railway-domain>/v1
export OPENAI_API_KEY=sk-...
aider --model dev-auto
```

## curl smoke test

```bash
curl -sS https://<your-railway-domain>/v1/chat/completions \
  -H "Authorization: Bearer $YOUR_VIRTUAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "dev-auto",
    "messages": [{"role": "user", "content": "reply with the single word: pong"}],
    "max_tokens": 8
  }'
```

You should see a JSON response containing `"content": "pong"` and a
`"model"` field telling you which backend actually served the call (handy
for confirming fallbacks).

## When something feels wrong

Track this manually in a notebook — it feeds directly into the daily report:

- **Did the model break flow?**  yes / no
- **Did you switch back to Claude or Cursor's default?**  yes / no — and why
- **Quality score for the session** (1–5, see `docs/metrics.md`)

Hand those numbers to `scripts/daily_report.py` via `--hours`, `--quality`,
and `--notes`.
