#!/usr/bin/env python3
"""
Summarize HealthKit raw QUANTITY data older than CUTOFF_MONTHS into daily aggregates.

Calls the server-side public.summarize_healthkit_metric() Postgres function, which
aggregates + deletes in a single transaction (no row-count cap, no partial-delete
data-loss risk). The function is invoked via the Supabase Management API SQL endpoint
rather than PostgREST RPC — PostgREST enforces a short statement timeout that aborts
the aggregate+delete on multi-million-row types.

EXCLUDED from summarization (kept raw indefinitely):
  - Category types (HKCategoryTypeIdentifier*) — sleep stages, symptoms. Their value
    is categorical and the metadata payload (sleep_stage) would be destroyed by averaging.
  - Workout type (HKWorkoutTypeIdentifier) — metadata (type, duration, distance, calories)
    is the payload; very low volume so no need to compress.

USAGE:
  python summarize_historical.py            # dry run — counts only, no changes
  python summarize_historical.py --execute  # runs the transactional summarization

Only run after the backfill is confirmed complete.
"""

import argparse
import os
from datetime import date, timedelta

import httpx
from dotenv import load_dotenv

load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), "../mcp-server/.env"))

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
SUPABASE_PAT = os.environ["SUPABASE_PAT"]
USER_ID = os.environ["HEALTHKIT_USER_ID"]
PROJECT_REF = SUPABASE_URL.replace("https://", "").replace(".supabase.co", "")
MGMT_URL = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
MGMT_HEADERS = {"Authorization": f"Bearer {SUPABASE_PAT}", "Content-Type": "application/json"}
CUTOFF_MONTHS = 1

HEADERS = {
    "apikey": SERVICE_ROLE_KEY,
    "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
    "Content-Type": "application/json",
}
API = f"{SUPABASE_URL}/rest/v1"


def cutoff_date() -> str:
    return (date.today() - timedelta(days=CUTOFF_MONTHS * 30)).isoformat()


def is_summarizable(metric_type: str) -> bool:
    """Only high-volume quantity types are safe to aggregate to daily stats."""
    if metric_type.startswith("HKCategoryTypeIdentifier"):
        return False
    if metric_type == "HKWorkoutTypeIdentifier":
        return False
    return True


def types_before(cutoff: str) -> list[str]:
    # PostgREST enforces a max-rows cap (~5000) regardless of limit=. Paging rows
    # to discover distinct types is non-deterministic. Use a server-side RPC instead.
    PAT = os.environ.get("SUPABASE_PAT", "")
    if not PAT:
        raise RuntimeError(
            "SUPABASE_PAT not set. Required for exact distinct-type query via Management API.\n"
            "Add SUPABASE_PAT=sbp_... to .env"
        )
    project_ref = SUPABASE_URL.replace("https://", "").replace(".supabase.co", "")
    resp = httpx.post(
        f"https://api.supabase.com/v1/projects/{project_ref}/database/query",
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json"},
        json={"query": (
            f"SELECT DISTINCT metric_type FROM public.healthkit_metrics "
            f"WHERE user_id = '{USER_ID}' "
            f"AND started_at < '{cutoff}T00:00:00+00:00'::timestamptz"
        )},
        timeout=120,
    )
    resp.raise_for_status()
    rows = resp.json()
    if not isinstance(rows, list):
        raise RuntimeError(f"Unexpected response from Management API: {rows}")
    return sorted(r["metric_type"] for r in rows)


def count_raw(metric_type: str, cutoff: str) -> int:
    # count=estimated uses planner stats for large tables (instant); exact counts
    # over millions of rows hit the PostgREST statement timeout (error 57014).
    resp = httpx.get(
        f"{API}/healthkit_metrics",
        headers={**HEADERS, "Prefer": "count=estimated"},
        params={
            "user_id": f"eq.{USER_ID}",
            "metric_type": f"eq.{metric_type}",
            "started_at": f"lt.{cutoff}T00:00:00+00:00",
            "select": "id",
            "limit": 1,
        },
        timeout=60,
    )
    resp.raise_for_status()
    # Content-Range header: "0-0/12345" (estimate)
    cr = resp.headers.get("content-range", "*/0")
    tail = cr.split("/")[-1]
    return int(tail) if tail.isdigit() else 0


def summarize(metric_type: str, cutoff: str) -> dict:
    """Run summarization via Management API to bypass PostgREST statement timeout."""
    sql = f"SELECT * FROM public.summarize_healthkit_metric('{USER_ID}', '{metric_type}', '{cutoff}')"
    resp = httpx.post(MGMT_URL, headers=MGMT_HEADERS, json={"query": sql}, timeout=600)
    resp.raise_for_status()
    return resp.json()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()

    cutoff = cutoff_date()
    print(f"Cutoff: {cutoff} ({CUTOFF_MONTHS} months ago)")
    print(f"Mode: {'EXECUTE' if args.execute else 'DRY RUN'}\n")

    all_types = types_before(cutoff)
    summarizable = [t for t in all_types if is_summarizable(t)]
    skipped = [t for t in all_types if not is_summarizable(t)]

    print(f"{len(all_types)} types have data before cutoff")
    print(f"  {len(summarizable)} summarizable (quantity)")
    print(f"  {len(skipped)} kept raw (category/workout): {', '.join(skipped) if skipped else 'none'}\n")

    total_raw = 0
    total_days = 0
    for mt in summarizable:
        if not args.execute:
            n = count_raw(mt, cutoff)
            total_raw += n
            print(f"  [dry-run] {mt}: {n:,} raw rows would be summarized")
            continue

        result = summarize(mt, cutoff)
        if result:
            raw = result[0].get("raw_count", 0)
            days = result[0].get("summary_days", 0)
            total_raw += raw
            total_days += days
            print(f"  {mt}: {raw:,} rows -> {days} daily summaries (raw deleted)")

    print(f"\nTotal raw rows {'would be' if not args.execute else ''} processed: {total_raw:,}")
    if args.execute:
        print(f"Total daily summary rows written: {total_days:,}")
    else:
        print("\nRe-run with --execute to apply (server-side transactional, no data-loss risk).")


if __name__ == "__main__":
    main()
