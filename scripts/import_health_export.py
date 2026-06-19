#!/usr/bin/env python3
"""
Import Apple Health export.xml into Supabase healthkit_metrics.

USAGE:
  1. On iPhone: Health app → profile pic (top-right) → Export All Health Data → AirDrop to Mac
  2. Unzip: unzip apple_health_export.zip -d ~/Desktop/health_export
  3. Run: python import_health_export.py ~/Desktop/health_export/apple_health_export/export.xml

Inserts directly via Supabase Management API — no Edge Function, no batch-size limit.
Safe to re-run: uses ON CONFLICT DO NOTHING (skips already-uploaded rows).
"""

import argparse
import os
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from dotenv import load_dotenv
import httpx

load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), "../mcp-server/.env"))

SUPABASE_URL   = os.environ["SUPABASE_URL"]
SUPABASE_PAT   = os.environ["SUPABASE_PAT"]
USER_ID        = os.environ["HEALTHKIT_USER_ID"]
PROJECT_REF    = SUPABASE_URL.replace("https://", "").replace(".supabase.co", "")
MGMT_QUERY_URL = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"

MGMT_HEADERS = {
    "Authorization": f"Bearer {SUPABASE_PAT}",
    "Content-Type": "application/json",
}

BATCH_SIZE = 2000  # rows per SQL INSERT — Management API has no PostgREST timeout
CHECKPOINT_FILE = os.path.join(os.path.dirname(__file__), ".import_checkpoint")

# Only HKRecord types we care about (skip clinical, ECG, audiogram, etc.)
# Keeps "HKQuantity..." and "HKCategory..." types; skips workouts (different schema)
SKIP_PREFIXES = (
    "HKWorkoutTypeIdentifier",
    "HKDataTypeSleepDurationGoal",
    "HKClinical",
)


def parse_hk_date(s: str) -> str:
    """Convert 'YYYY-MM-DD HH:MM:SS ±HHMM' to ISO8601 with timezone for Postgres."""
    # Apple exports dates like "2013-06-25 19:45:12 -0400"
    try:
        dt = datetime.strptime(s, "%Y-%m-%d %H:%M:%S %z")
        return dt.isoformat()
    except ValueError:
        return s


import re as _re

_HK_TYPE_RE = _re.compile(r'^HK[A-Za-z]+$')


def _dq(tag: str, s: str) -> str:
    """Dollar-quote a string value — safe against any single-quote or backslash content."""
    return f"${tag}${s}${tag}$"


def build_insert_sql(rows: list[dict]) -> str:
    values = []
    for i, r in enumerate(rows):
        mt = r["metric_type"]
        if not _HK_TYPE_RE.match(mt):
            raise ValueError(f"Unexpected metric_type at row {i}: {mt!r}")
        val     = r["value"] if r["value"] is not None else "NULL"
        unit    = _dq(f"u{i}", r.get("unit", ""))
        src     = _dq(f"s{i}", r.get("source_device", ""))
        started = _dq(f"st{i}", r["started_at"])
        ended   = _dq(f"e{i}", r["ended_at"]) if r.get("ended_at") else "NULL"
        uid     = _dq(f"id{i}", USER_ID)
        mtq     = _dq(f"m{i}", mt)
        values.append(
            f"({uid},{mtq},{val},{unit},{src},{started},{ended},NULL,now())"
        )
    vals_str = ",\n".join(values)
    return f"""
INSERT INTO public.healthkit_metrics
    (user_id, metric_type, value, unit, source_device, started_at, ended_at, metadata, synced_at)
VALUES
{vals_str}
ON CONFLICT (user_id, metric_type, started_at) DO NOTHING;
"""


def run_sql(sql: str, client: httpx.Client) -> int:
    for attempt in range(5):
        try:
            resp = client.post(MGMT_QUERY_URL, headers=MGMT_HEADERS, json={"query": sql}, timeout=120)
            if resp.status_code in (502, 503, 504):
                wait = 2 ** attempt
                print(f"\n  [{resp.status_code}] retrying in {wait}s (attempt {attempt+1}/5)...")
                time.sleep(wait)
                continue
            resp.raise_for_status()
            result = resp.json()
            if isinstance(result, list) and result and "count" in result[0]:
                return result[0]["count"]
            return 0
        except httpx.TimeoutException:
            wait = 2 ** attempt
            print(f"\n  [timeout] retrying in {wait}s (attempt {attempt+1}/5)...")
            time.sleep(wait)
    raise RuntimeError("Failed after 5 retries")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("export_xml", help="Path to export.xml from Apple Health export")
    parser.add_argument("--dry-run", action="store_true", help="Parse only, no inserts")
    args = parser.parse_args()

    xml_path = os.path.expanduser(args.export_xml)
    if not os.path.exists(xml_path):
        print(f"ERROR: File not found: {xml_path}")
        sys.exit(1)

    file_size_mb = os.path.getsize(xml_path) / 1024 / 1024
    print(f"Parsing: {xml_path} ({file_size_mb:.0f} MB)")
    print(f"Mode: {'DRY RUN' if args.dry_run else 'LIVE INSERT'}")
    print(f"Batch size: {BATCH_SIZE} rows\n")

    # Resume support: skip rows already inserted in a previous run
    resume_from = 0
    if os.path.exists(CHECKPOINT_FILE) and not args.dry_run:
        try:
            resume_from = int(open(CHECKPOINT_FILE).read().strip())
            print(f"Resuming from row {resume_from:,}\n")
        except Exception:
            pass

    batch: list[dict] = []
    total_parsed = 0
    total_skipped = 0
    total_inserted = 0
    start_time = time.time()

    # Track per-type stats for the summary
    type_counts: dict[str, int] = {}

    with httpx.Client() as client:
        # iterparse streams the XML — handles multi-GB files without loading into RAM
        context = ET.iterparse(xml_path, events=("end",))

        for event, elem in context:
            if elem.tag != "Record":
                elem.clear()
                continue

            metric_type = elem.attrib.get("type", "")

            # Skip non-quantity/category types
            if any(metric_type.startswith(p) for p in SKIP_PREFIXES):
                total_skipped += 1
                elem.clear()
                continue

            raw_value = elem.attrib.get("value")
            try:
                value = float(raw_value) if raw_value is not None else None
            except (ValueError, TypeError):
                value = None

            started_at_raw = elem.attrib.get("startDate", "")
            ended_at_raw   = elem.attrib.get("endDate", "")

            row = {
                "metric_type":   metric_type,
                "value":         value,
                "unit":          elem.attrib.get("unit", "")[:256],
                "source_device": elem.attrib.get("sourceName", "")[:256],
                "started_at":    parse_hk_date(started_at_raw),
                "ended_at":      parse_hk_date(ended_at_raw) if ended_at_raw else None,
            }

            total_parsed += 1

            # Skip rows already inserted in a previous run
            if total_parsed <= resume_from:
                elem.clear()
                continue

            batch.append(row)
            type_counts[metric_type] = type_counts.get(metric_type, 0) + 1

            if len(batch) >= BATCH_SIZE:
                if not args.dry_run:
                    sql = build_insert_sql(batch)
                    run_sql(sql, client)
                    open(CHECKPOINT_FILE, "w").write(str(total_parsed))
                total_inserted += len(batch)
                elapsed = time.time() - start_time
                rate = total_parsed / elapsed
                print(
                    f"  Inserted {total_inserted:,} rows | parsed {total_parsed:,} | "
                    f"{rate:.0f} rows/s | elapsed {elapsed:.0f}s",
                    end="\r",
                )
                batch.clear()
                elem.clear()
                continue

            elem.clear()

        # Final partial batch
        if batch:
            if not args.dry_run:
                sql = build_insert_sql(batch)
                run_sql(sql, client)
                open(CHECKPOINT_FILE, "w").write(str(total_parsed))
            total_inserted += len(batch)

    # Clear checkpoint on clean finish
    if not args.dry_run and os.path.exists(CHECKPOINT_FILE):
        os.remove(CHECKPOINT_FILE)

    elapsed = time.time() - start_time
    print(f"\n\nDone in {elapsed:.0f}s ({elapsed/60:.1f} min)")
    print(f"  Parsed:  {total_parsed:,} records")
    print(f"  Skipped: {total_skipped:,} (workouts/clinical)")
    print(f"  Batched: {total_inserted:,} rows {'(dry run — not inserted)' if args.dry_run else 'inserted'}")
    print(f"\nTop metric types:")
    for mt, cnt in sorted(type_counts.items(), key=lambda x: -x[1])[:15]:
        short = mt.replace("HKQuantityTypeIdentifier", "").replace("HKCategoryTypeIdentifier", "Cat:")
        print(f"  {short}: {cnt:,}")


if __name__ == "__main__":
    main()
