# Metrics

The point of Phase 1 is to answer one question:

> What does one heavy premium developer actually cost us per day/month?

Every metric below feeds that answer.

## Per-request fields we must capture

LiteLLM + Langfuse populate most of this automatically. Anything missing
becomes a callback / middleware task in a later phase.

| Field                       | Source                  | Notes                                    |
| --------------------------- | ----------------------- | ---------------------------------------- |
| `timestamp`                 | LiteLLM `startTime`     |                                          |
| `user_id`                   | virtual key metadata    | set by `generate_key.sh`                 |
| `api_key_hash`              | LiteLLM `api_key`       | hashed, never the raw key                |
| `client_app`                | request `User-Agent`    | seen in Langfuse trace metadata          |
| `model_requested`           | metadata.requested_model| the alias the client sent (e.g. dev-auto)|
| `model_used`                | LiteLLM `model`         | what actually served the call            |
| `fallback_chain`            | router config           | derived from active config + Langfuse    |
| `fallback_used`             | derived                 | `model_used != model_requested`          |
| `route_reason`              | metadata                | populated when we add a routing classifier|
| `input_tokens`              | LiteLLM `prompt_tokens` |                                          |
| `output_tokens`             | LiteLLM `completion_tokens` |                                      |
| `total_tokens`              | LiteLLM `total_tokens`  |                                          |
| `cost_usd`                  | LiteLLM `spend`         | uses `model_info.input/output_cost_per_token` |
| `latency_ms`                | derived (`endTime-startTime`) |                                    |
| `time_to_first_token_ms`    | Langfuse                | streaming only                           |
| `tokens_per_second`         | Langfuse                | streaming only                           |
| `error_type`                | metadata.error          |                                          |
| `retry_count`               | LiteLLM logs            |                                          |
| `status_code`               | LiteLLM logs            |                                          |

If any field is missing once you start running the test, the fix lives in
LiteLLM's `success_callback` / `failure_callback` — bolt on a thin Python
hook rather than scraping logs.

## Daily summary (calculated)

`scripts/daily_report.py` produces these numbers per UTC day:

- daily total cost (USD)
- daily input tokens
- daily output tokens
- cost by model
- tokens by model
- requests by model
- fallback rate (% of completed calls where `model_used != model_requested`)
- average latency by model
- P95 latency by model
- errors by model
- estimated monthly cost at current pace (`daily_cost × 20 workdays`)
- cost per productive dev hour (manual `--hours` input)
- premium model share (% of calls served by MiMo-Pro or DS-V4-Pro)

The example summary lines up exactly with the spec template:

```text
Date: 2026-05-03
Mode: A Premium-Heavy
Dev hours: 4.2
Requests: 318
Input tokens: 42.1M
Output tokens: 820k
Total API cost: $27.40
Cost/dev-hour: $6.52
Projected 20-workday cost: $548.00
Fallback rate: 8.4%
Premium model share: 91%
Quality score: 4.5/5
Notes: Great for architecture, slightly slower in Cursor autocomplete.
```

## Quality score (subjective, 1–5)

After every meaningful work session:

| Score | Meaning                                            |
| :---: | -------------------------------------------------- |
|   1   | unacceptable                                       |
|   2   | noticeably worse than Claude/Cursor                |
|   3   | usable but frustrating                             |
|   4   | close enough for most dev work                     |
|   5   | equal or better than Claude/Cursor                 |

Also write down:

- number of times you manually switched back to Claude/Cursor
- the reason for switching
- the model mode active at the time
- **did the model break flow?** — the most important subjective metric

## Business decision metrics (after 10–15 workdays)

After a full Mode A + Mode B run, compute:

- average daily cost
- average monthly cost at 20 workdays
- cost per dev hour
- quality score by mode
- fallback percentage
- premium model percentage
- Claude rescue percentage (manual switches back to Claude / total sessions)

### Pricing tier interpretation

| Monthly cost for Jonathan | Interpretation                                       |
| ------------------------: | ---------------------------------------------------- |
|                     <$100 | $199/mo plan is very viable                          |
|                 $100–$200 | $299/mo plan likely viable                           |
|                 $200–$400 | Need $499 power tier or routing optimization         |
|                 $400–$800 | Needs fair-use controls, throttling, or high-end tier|
|                     $800+ | True unlimited for power users is not viable         |

### Product-viability target

- Quality: **4+/5**
- Monthly cost for Jonathan: **<$250 ideal**
- Claude rescue rate: **<10%**
- Premium fallback rate: controlled and explainable

## Where to look

- **LiteLLM admin UI** — `http://localhost:4000/ui` (master key auth) for
  per-key spend, budgets, and live request logs.
- **Langfuse** — full traces, latency breakdowns, prompt/response inspection,
  TTFT and tok/s for streaming requests.
- **`scripts/daily_report.py`** — the canonical daily roll-up; commit its
  JSON output under `reports/` for trend analysis.
