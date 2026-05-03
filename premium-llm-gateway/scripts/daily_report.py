#!/usr/bin/env python3
"""
daily_report.py — Premium LLM Gateway daily cost & quality report.

Pulls spend rows from the LiteLLM admin API (`/spend/logs`) for a given UTC
date and prints the summary format defined in the spec. Optionally writes a
machine-readable JSON file plus a human-readable Markdown file under
`reports/`.

Zero third-party deps — uses only the Python stdlib.

Usage:
  ./scripts/daily_report.py                       # today, prompt for hours
  ./scripts/daily_report.py --date 2026-05-03 --hours 4.2 --mode A
  ./scripts/daily_report.py --hours 4 --quality 4.5 --notes "Great"
  ./scripts/daily_report.py --base-url https://api.example.com --json

Env (auto-loaded from ../.env):
  LITELLM_BASE_URL    default: http://localhost:4000
  LITELLM_MASTER_KEY  required (admin auth)
  ACTIVE_MODE         informational tag, e.g. A | B | C
"""

from __future__ import annotations

import argparse
import json
import math
import os
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env"
REPORTS_DIR = REPO_ROOT / "reports"
WORKDAYS_PER_MONTH = 20  # business definition baked into the spec


# ---------------------------------------------------------------------------
# tiny dotenv loader (no dependency)
# ---------------------------------------------------------------------------

def load_dotenv(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


# ---------------------------------------------------------------------------
# LiteLLM admin client
# ---------------------------------------------------------------------------

class LiteLLMClient:
    def __init__(self, base_url: str, master_key: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.master_key = master_key

    def _get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        url = f"{self.base_url}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(
            url,
            headers={"Authorization": f"Bearer {self.master_key}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise SystemExit(f"HTTP {e.code} on {path}: {body}") from e
        except urllib.error.URLError as e:
            raise SystemExit(f"Cannot reach {url}: {e}") from e

    def spend_logs(self, start: datetime, end: datetime) -> list[dict[str, Any]]:
        """
        LiteLLM exposes `/spend/logs` accepting `start_date` / `end_date` in
        ISO-ish format. Some versions accept `YYYY-MM-DD`, others a full
        ISO timestamp; we send ISO with timezone for safety.
        """
        rows = self._get(
            "/spend/logs",
            {"start_date": start.isoformat(), "end_date": end.isoformat()},
        )
        if isinstance(rows, dict) and "data" in rows:
            rows = rows["data"]
        return rows or []


# ---------------------------------------------------------------------------
# metric helpers
# ---------------------------------------------------------------------------

def _percentile(values: Iterable[float], pct: float) -> float | None:
    vals = sorted(values)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    # nearest-rank percentile, plenty good for ~hundreds of samples
    k = max(0, min(len(vals) - 1, math.ceil(pct / 100 * len(vals)) - 1))
    return vals[k]


def _latency_ms(row: dict[str, Any]) -> float | None:
    start = row.get("startTime") or row.get("start_time")
    end = row.get("endTime") or row.get("end_time")
    if not start or not end:
        return None
    try:
        s = datetime.fromisoformat(str(start).replace("Z", "+00:00"))
        e = datetime.fromisoformat(str(end).replace("Z", "+00:00"))
        return max(0.0, (e - s).total_seconds() * 1000.0)
    except ValueError:
        return None


def _requested_alias(row: dict[str, Any]) -> str | None:
    """The model the *client* asked for, before any fallback resolution."""
    md = row.get("metadata") or {}
    if isinstance(md, str):
        try:
            md = json.loads(md)
        except json.JSONDecodeError:
            md = {}
    return (
        md.get("requested_model")
        or md.get("model_group")
        or md.get("user_api_key_model")
    )


def _is_error(row: dict[str, Any]) -> bool:
    if row.get("status") and str(row["status"]).lower() not in ("success", "ok", "200"):
        return True
    md = row.get("metadata") or {}
    if isinstance(md, str):
        try:
            md = json.loads(md)
        except json.JSONDecodeError:
            return False
    return bool(md.get("error") or md.get("error_information"))


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    by_model: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "requests": 0,
            "errors": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "total_tokens": 0,
            "cost_usd": 0.0,
            "_latencies": [],
        }
    )

    total_requests = 0
    total_errors = 0
    total_fallbacks = 0
    total_input = 0
    total_output = 0
    total_cost = 0.0

    for row in rows:
        model = row.get("model") or "unknown"
        m = by_model[model]
        m["requests"] += 1
        total_requests += 1

        if _is_error(row):
            m["errors"] += 1
            total_errors += 1

        in_tok = int(row.get("prompt_tokens") or 0)
        out_tok = int(row.get("completion_tokens") or 0)
        m["input_tokens"] += in_tok
        m["output_tokens"] += out_tok
        m["total_tokens"] += in_tok + out_tok
        total_input += in_tok
        total_output += out_tok

        spend = float(row.get("spend") or 0.0)
        m["cost_usd"] += spend
        total_cost += spend

        latency = _latency_ms(row)
        if latency is not None:
            m["_latencies"].append(latency)

        alias = _requested_alias(row)
        if alias and alias != model:
            total_fallbacks += 1

    # finalise per-model latency stats
    for model, m in by_model.items():
        lats = m.pop("_latencies")
        m["avg_latency_ms"] = round(statistics.mean(lats), 1) if lats else None
        m["p95_latency_ms"] = round(_percentile(lats, 95) or 0.0, 1) if lats else None

    fallback_rate = (total_fallbacks / total_requests) if total_requests else 0.0

    # premium share = % of completed calls served by MiMo or DS-Pro
    premium_models = {"mimo-pro", "deepseek-v4-pro"}
    premium_calls = sum(
        m["requests"] for name, m in by_model.items() if name in premium_models
    )
    premium_share = (premium_calls / total_requests) if total_requests else 0.0

    return {
        "totals": {
            "requests": total_requests,
            "errors": total_errors,
            "fallbacks": total_fallbacks,
            "fallback_rate": round(fallback_rate, 4),
            "premium_model_share": round(premium_share, 4),
            "input_tokens": total_input,
            "output_tokens": total_output,
            "total_tokens": total_input + total_output,
            "cost_usd": round(total_cost, 4),
            "projected_monthly_usd": round(total_cost * WORKDAYS_PER_MONTH, 2),
        },
        "by_model": dict(by_model),
    }


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def render_text(
    day: date,
    mode: str,
    dev_hours: float | None,
    quality: float | None,
    notes: str,
    summary: dict[str, Any],
) -> str:
    t = summary["totals"]
    lines: list[str] = []
    lines.append(f"Date: {day.isoformat()}")
    lines.append(f"Mode: {mode}")
    if dev_hours is not None:
        lines.append(f"Dev hours: {dev_hours}")
    lines.append(f"Requests: {t['requests']}")
    lines.append(f"Input tokens: {_fmt_tokens(t['input_tokens'])}")
    lines.append(f"Output tokens: {_fmt_tokens(t['output_tokens'])}")
    lines.append(f"Total API cost: ${t['cost_usd']:.2f}")
    if dev_hours and dev_hours > 0:
        lines.append(f"Cost/dev-hour: ${t['cost_usd'] / dev_hours:.2f}")
    lines.append(
        f"Projected {WORKDAYS_PER_MONTH}-workday cost: ${t['projected_monthly_usd']:.2f}"
    )
    lines.append(f"Fallback rate: {t['fallback_rate'] * 100:.1f}%")
    lines.append(f"Premium model share: {t['premium_model_share'] * 100:.0f}%")
    if quality is not None:
        lines.append(f"Quality score: {quality}/5")
    if notes:
        lines.append(f"Notes: {notes}")

    lines.append("")
    lines.append("By model:")
    header = (
        f"  {'model':<22} {'reqs':>5} {'err':>4} "
        f"{'in_tok':>8} {'out_tok':>8} {'cost$':>8} "
        f"{'avg_ms':>7} {'p95_ms':>7}"
    )
    lines.append(header)
    for name, m in sorted(
        summary["by_model"].items(), key=lambda kv: -kv[1]["cost_usd"]
    ):
        lines.append(
            f"  {name:<22} {m['requests']:>5} {m['errors']:>4} "
            f"{_fmt_tokens(m['input_tokens']):>8} {_fmt_tokens(m['output_tokens']):>8} "
            f"{m['cost_usd']:>8.2f} "
            f"{(m['avg_latency_ms'] or 0):>7.0f} {(m['p95_latency_ms'] or 0):>7.0f}"
        )
    return "\n".join(lines)


def render_markdown(text: str) -> str:
    return f"```text\n{text}\n```\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Premium LLM Gateway daily report")
    p.add_argument("--date", help="UTC date YYYY-MM-DD (default: today)")
    p.add_argument(
        "--hours", type=float, default=None,
        help="productive dev hours for the day (manual entry)",
    )
    p.add_argument("--mode", default=os.environ.get("ACTIVE_MODE", "A"))
    p.add_argument("--quality", type=float, default=None,
                   help="subjective quality score 1-5")
    p.add_argument("--notes", default="", help="free-form notes")
    p.add_argument("--base-url", default=None, help="LiteLLM admin base URL")
    p.add_argument("--master-key", default=None, help="LiteLLM master key")
    p.add_argument("--json", action="store_true",
                   help="also write JSON+Markdown into ./reports/")
    p.add_argument("--no-prompt", action="store_true",
                   help="never prompt interactively for missing values")
    return p.parse_args()


def main() -> int:
    load_dotenv(ENV_FILE)
    args = parse_args()

    base_url = args.base_url or os.environ.get(
        "LITELLM_BASE_URL", "http://localhost:4000"
    )
    master_key = args.master_key or os.environ.get("LITELLM_MASTER_KEY", "")
    if not master_key or master_key == "sk-admin-replace-me":
        print(
            "ERROR: LITELLM_MASTER_KEY is unset or still the placeholder.",
            file=sys.stderr,
        )
        return 2

    if args.date:
        day = date.fromisoformat(args.date)
    else:
        day = datetime.now(timezone.utc).date()

    start = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc)
    end = start + timedelta(days=1)

    dev_hours = args.hours
    if dev_hours is None and not args.no_prompt and sys.stdin.isatty():
        try:
            raw = input("Productive dev hours today (blank to skip): ").strip()
            dev_hours = float(raw) if raw else None
        except (EOFError, ValueError):
            dev_hours = None

    quality = args.quality
    if quality is None and not args.no_prompt and sys.stdin.isatty():
        try:
            raw = input("Quality score 1-5 (blank to skip): ").strip()
            quality = float(raw) if raw else None
        except (EOFError, ValueError):
            quality = None

    client = LiteLLMClient(base_url, master_key)
    rows = client.spend_logs(start, end)
    summary = summarize(rows)

    text = render_text(day, args.mode, dev_hours, quality, args.notes, summary)
    print(text)

    if args.json:
        REPORTS_DIR.mkdir(exist_ok=True)
        stem = REPORTS_DIR / day.isoformat()
        payload = {
            "date": day.isoformat(),
            "mode": args.mode,
            "dev_hours": dev_hours,
            "quality": quality,
            "notes": args.notes,
            "summary": summary,
        }
        stem.with_suffix(".json").write_text(json.dumps(payload, indent=2))
        stem.with_suffix(".md").write_text(render_markdown(text))
        print(f"\nWrote {stem.with_suffix('.json')} and {stem.with_suffix('.md')}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
