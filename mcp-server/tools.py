"""
MCP tool implementations — reads from Supabase.
Routing: queries within 30 days use raw healthkit_metrics;
queries beyond 30 days use healthkit_daily_summaries (aggregated).
"""

from datetime import datetime, date, timedelta, timezone
from zoneinfo import ZoneInfo

NY = ZoneInfo("America/New_York")
import os
import httpx
from dotenv import load_dotenv

load_dotenv()

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
DEFAULT_USER_ID = os.environ.get("HEALTHKIT_USER_ID", "")

POSTGREST = f"{SUPABASE_URL}/rest/v1"
HEADERS = {
    "apikey": SERVICE_ROLE_KEY,
    "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
    "Prefer": "count=none",
}
TABLE = "healthkit_metrics"
SUMMARY_TABLE = "healthkit_daily_summaries"
RAW_CUTOFF_DAYS = 30  # beyond this, queries hit daily summaries

# Common HealthKit metric type identifiers
STEPS = "HKQuantityTypeIdentifierStepCount"
HEART_RATE = "HKQuantityTypeIdentifierHeartRate"
HRV = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
RESTING_HR = "HKQuantityTypeIdentifierRestingHeartRate"
VO2MAX = "HKQuantityTypeIdentifierVO2Max"
ACTIVE_ENERGY = "HKQuantityTypeIdentifierActiveEnergyBurned"
SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"
WEIGHT = "HKQuantityTypeIdentifierBodyMass"
WORKOUT = "HKWorkoutTypeIdentifier"


def _get(metric_type: str, user_id: str, since: str, limit: int = 500,
         source_filter: str | None = None) -> list[dict]:
    # PostgREST enforces max-rows ~5000 per page. Paginate to collect all rows
    # up to `limit`. For raw queries (not tiered), callers pass explicit limits
    # (e.g. 50 for workouts, 500 for recent HRV) that stay under the cap.
    # _get_tiered_daily passes limit=100000 — paginate those.
    # source_filter: optional substring match on source_device (e.g. "Oura" for sleep).
    PAGE = 5000
    all_rows: list[dict] = []
    offset = 0
    while len(all_rows) < limit:
        fetch = min(PAGE, limit - len(all_rows))
        params: dict = {
            "user_id": f"eq.{user_id}",
            "metric_type": f"eq.{metric_type}",
            "started_at": f"gte.{since}",
            "order": "started_at.desc",
            "limit": fetch,
            "offset": offset,
        }
        if source_filter:
            params["source_device"] = f"ilike.*{source_filter}*"
        resp = httpx.get(
            f"{POSTGREST}/{TABLE}",
            headers=HEADERS,
            params=params,
            timeout=30,
        )
        resp.raise_for_status()
        page = resp.json()
        if not page:
            break
        all_rows.extend(page)
        if len(page) < fetch:
            break
        offset += fetch
    return all_rows


def _since(days: int) -> str:
    dt = datetime.now(timezone.utc) - timedelta(days=days)
    return dt.isoformat()


def _ny_date(iso: str) -> str:
    """Convert an ISO timestamp string to America/New_York calendar date (YYYY-MM-DD)."""
    dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return dt.astimezone(NY).strftime("%Y-%m-%d")


def _daily_from_raw(rows: list[dict]) -> list[dict]:
    """Collapse raw samples into daily aggregates (America/New_York day boundaries)."""
    daily: dict[str, list[float]] = {}
    for r in rows:
        if r.get("value") is None:
            continue
        daily.setdefault(_ny_date(r["started_at"]), []).append(r["value"])
    out = []
    for d, vals in sorted(daily.items()):
        out.append({
            "date": d,
            "avg_value": round(sum(vals) / len(vals), 4),
            "min_value": min(vals),
            "max_value": max(vals),
            "sum_value": round(sum(vals), 4),
            "sample_count": len(vals),
            "source": "raw",
        })
    return out


def _get_tiered_daily(metric_type: str, user_id: str, days: int) -> list[dict]:
    """
    Daily-aggregated series spanning `days`, transparently merging tiers:
      - recent window (<= RAW_CUTOFF_DAYS): raw samples aggregated to daily
      - older window (> RAW_CUTOFF_DAYS): pre-aggregated daily summaries
    Returns one chronological list. Each point carries source='raw'|'summary'.
    """
    today = datetime.now(timezone.utc).date()
    cutoff = (today - timedelta(days=RAW_CUTOFF_DAYS)).isoformat()
    window_start = (today - timedelta(days=days)).isoformat()

    # Recent raw portion (from max(window_start, cutoff) forward)
    raw_since = max(window_start, cutoff)
    raw_rows = _get(metric_type, user_id, f"{raw_since}T00:00:00+00:00", limit=100000)
    recent_daily = _daily_from_raw(raw_rows)

    # Historical summary portion — only days strictly before the raw cutoff (no overlap)
    historical_daily: list[dict] = []
    if days > RAW_CUTOFF_DAYS:
        for s in _get_summaries(metric_type, user_id, window_start, limit=10000):
            if s["date"] < cutoff:
                historical_daily.append({**s, "source": "summary"})

    combined = historical_daily + recent_daily
    combined.sort(key=lambda x: x["date"])
    return combined


def _weighted_mean(points: list[dict]) -> float | None:
    """Exact mean across daily points: sum(sum_value) / sum(sample_count).
    Use only for rate/level metrics (HRV, HR, VO2Max). For cumulative metrics
    (steps, energy, distance), use _daily_total_avg() instead."""
    total_sum = sum(p["sum_value"] for p in points if p.get("sum_value") is not None)
    total_n = sum(p["sample_count"] for p in points if p.get("sample_count"))
    return round(total_sum / total_n, 2) if total_n else None


def _daily_total_avg(points: list[dict]) -> float | None:
    """Average daily total for cumulative metrics (steps, energy, distance).
    Each point is one day; sum_value is the day's total. Returns mean across days."""
    totals = [p["sum_value"] for p in points if p.get("sum_value") is not None]
    return round(sum(totals) / len(totals), 1) if totals else None


# Metrics where the meaningful number is the daily total (not mean of intervals)
_CUMULATIVE_METRICS = {
    STEPS,
    ACTIVE_ENERGY,
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierDistanceCycling",
    "HKQuantityTypeIdentifierBasalEnergyBurned",
    "HKQuantityTypeIdentifierAppleExerciseTime",
    "HKQuantityTypeIdentifierFlightsClimbed",
}


def _avg_daily_total_from_raw(rows: list[dict]) -> float | None:
    """For cumulative metrics: sum intervals per NY calendar day, then average across days."""
    daily: dict[str, float] = {}
    for r in rows:
        if r.get("value") is None:
            continue
        day = _ny_date(r["started_at"])
        daily[day] = daily.get(day, 0.0) + r["value"]
    totals = list(daily.values())
    return round(sum(totals) / len(totals), 1) if totals else None


def get_health_summary(days: int = 7, user_id: str = "") -> dict:
    """
    Overview of key health metrics for the past N days.
    Returns avg steps, avg sleep, avg HRV, avg resting HR, workout count.
    """
    uid = user_id or DEFAULT_USER_ID
    since = _since(days)

    steps_rows = _get(STEPS, uid, since)
    hrv_rows = _get(HRV, uid, since)
    resting_hr_rows = _get(RESTING_HR, uid, since)
    sleep_rows = _get(SLEEP, uid, since)
    workout_rows = _get(WORKOUT, uid, since, limit=50)

    def avg(rows: list[dict]) -> float | None:
        vals = [r["value"] for r in rows if r.get("value") is not None]
        return round(sum(vals) / len(vals), 1) if vals else None

    def total(rows: list[dict]) -> float | None:
        vals = [r["value"] for r in rows if r.get("value") is not None]
        return round(sum(vals), 0) if vals else None

    # Sleep: sum duration of "asleep" stages per day
    sleep_stages = [
        r for r in sleep_rows
        if r.get("metadata", {}) and "sleep" in str(r.get("metadata", {})).lower()
    ]

    return {
        "period_days": days,
        "steps": {
            "total": total(steps_rows),
            "daily_avg": _avg_daily_total_from_raw(steps_rows),
            "days_with_data": len({r["started_at"][:10] for r in steps_rows}),
        },
        "hrv_sdnn_ms": {
            "avg": avg(hrv_rows),
            "latest": hrv_rows[0]["value"] if hrv_rows else None,
            "readings": len(hrv_rows),
        },
        "resting_heart_rate_bpm": {
            "avg": avg(resting_hr_rows),
            "latest": resting_hr_rows[0]["value"] if resting_hr_rows else None,
        },
        "sleep": {
            "total_records": len(sleep_rows),
            "stage_records": len(sleep_stages),
        },
        "workouts": {
            "count": len(workout_rows),
            "types": list({r.get("metadata", {}).get("workout_type", "unknown") for r in workout_rows}),
        },
        "data_as_of": datetime.now(timezone.utc).isoformat(),
    }


def get_sleep(days: int = 7, user_id: str = "") -> dict:
    """
    Sleep analysis for the past N days.
    Returns per-night breakdown with stage durations (REM, Deep/Core, Light, Awake).
    """
    uid = user_id or DEFAULT_USER_ID
    since = _since(days)
    # Oura Ring syncs sleep stages to Apple Health — use as the single sleep source.
    # Apple Watch also writes stages; summing both would double-count every night.
    rows = _get(SLEEP, uid, since, limit=500, source_filter="Oura")

    nights: dict[str, dict] = {}

    # HKCategoryValueSleepAnalysis: 0=InBed, 1=AsleepUnspecified, 2=Awake,
    # 3=AsleepCore, 4=AsleepDeep, 5=AsleepREM. Only count 3/4/5 (true sleep stages).
    _STAGE_NAMES = {3.0: "core", 4.0: "deep", 5.0: "rem"}

    for row in rows:
        val = row.get("value")
        if val not in _STAGE_NAMES:
            continue

        started = row["started_at"]
        ended = row.get("ended_at")
        if not ended:
            continue

        start_dt = datetime.fromisoformat(started.replace("Z", "+00:00"))
        end_dt = datetime.fromisoformat(ended.replace("Z", "+00:00"))
        duration_min = round((end_dt - start_dt).total_seconds() / 60, 1)

        # Group by the calendar date of sleep start (shifted: sleep before 6am = previous night)
        night_start = start_dt - timedelta(hours=6)
        night_key = night_start.strftime("%Y-%m-%d")

        if night_key not in nights:
            nights[night_key] = {"date": night_key, "stages": {}, "total_minutes": 0, "segments": []}

        stage = _STAGE_NAMES[val]
        nights[night_key]["stages"].setdefault(stage, 0)
        nights[night_key]["stages"][stage] += duration_min
        nights[night_key]["total_minutes"] += duration_min
        nights[night_key]["segments"].append({
            "stage": stage,
            "started_at": started,
            "ended_at": ended,
            "duration_minutes": duration_min,
        })

    sorted_nights = sorted(nights.values(), key=lambda n: n["date"], reverse=True)

    # Compute summary
    total_hours = [n["total_minutes"] / 60 for n in sorted_nights if n["total_minutes"] > 0]
    avg_hours = round(sum(total_hours) / len(total_hours), 1) if total_hours else None

    return {
        "period_days": days,
        "avg_sleep_hours": avg_hours,
        "nights": sorted_nights,
    }


def get_hrv_trend(days: int = 30, user_id: str = "") -> dict:
    """
    HRV (SDNN) trend over the past N days.
    Returns daily averages, 7-day rolling comparison, and trend direction.
    Tier-aware: windows beyond 30 days transparently use daily summaries.
    """
    uid = user_id or DEFAULT_USER_ID
    points = _get_tiered_daily(HRV, uid, days)

    daily_avgs = [
        {"date": p["date"], "avg_hrv_ms": round(p["avg_value"], 1), "source": p["source"]}
        for p in points if p.get("avg_value") is not None
    ]

    # Trend: compare last 7 days vs prior 7 days of daily averages
    trend = None
    if len(daily_avgs) >= 14:
        recent = [d["avg_hrv_ms"] for d in daily_avgs[-7:]]
        prior = [d["avg_hrv_ms"] for d in daily_avgs[-14:-7]]
        delta = round(sum(recent) / len(recent) - sum(prior) / len(prior), 1)
        trend = {"delta_ms": delta, "direction": "improving" if delta > 0 else "declining" if delta < 0 else "stable"}

    return {
        "period_days": days,
        "days_with_data": len(daily_avgs),
        "avg_hrv_ms": _weighted_mean(points),
        "latest_hrv_ms": daily_avgs[-1]["avg_hrv_ms"] if daily_avgs else None,
        "trend_vs_prior_week": trend,
        "daily_averages": daily_avgs,
    }


def query_metric(
    metric_type: str,
    days: int = 7,
    user_id: str = "",
    limit: int = 200,
) -> dict:
    """
    Time-series for any HealthKit metric type.
    metric_type: e.g. 'HKQuantityTypeIdentifierStepCount', 'HKQuantityTypeIdentifierHeartRate'
    Windows <= 30 days return raw samples; longer windows return daily aggregates
    (raw samples beyond 30 days are summarized and no longer stored individually).
    """
    uid = user_id or DEFAULT_USER_ID

    if days > RAW_CUTOFF_DAYS:
        points = _get_tiered_daily(metric_type, uid, days)
        _avg_fn = _daily_total_avg if metric_type in _CUMULATIVE_METRICS else _weighted_mean
        return {
            "metric_type": metric_type,
            "period_days": days,
            "granularity": "daily",
            "count": len(points),
            "avg": _avg_fn(points),
            "min": min((p["min_value"] for p in points if p.get("min_value") is not None), default=None),
            "max": max((p["max_value"] for p in points if p.get("max_value") is not None), default=None),
            "daily": [
                {"date": p["date"], "avg": p["avg_value"], "min": p["min_value"],
                 "max": p["max_value"], "sum": p["sum_value"], "count": p["sample_count"],
                 "source": p["source"]}
                for p in points
            ],
        }

    since = _since(days)
    rows = _get(metric_type, uid, since, limit=limit)

    values = [r["value"] for r in rows if r.get("value") is not None]
    return {
        "metric_type": metric_type,
        "period_days": days,
        "granularity": "raw",
        "count": len(rows),
        "avg": round(sum(values) / len(values), 2) if values else None,
        "min": min(values) if values else None,
        "max": max(values) if values else None,
        "samples": [
            {
                "value": r["value"],
                "unit": r.get("unit"),
                "started_at": r["started_at"],
                "ended_at": r.get("ended_at"),
                "source": r.get("source_device"),
                "metadata": r.get("metadata"),
            }
            for r in rows
        ],
    }


def get_workouts(days: int = 30, limit: int = 20, user_id: str = "") -> dict:
    """
    Recent workouts with type, duration, distance, and calories.
    """
    uid = user_id or DEFAULT_USER_ID
    since = _since(days)
    rows = _get(WORKOUT, uid, since, limit=limit)

    workouts = []
    for r in rows:
        meta = r.get("metadata") or {}
        workouts.append({
            "date": r["started_at"][:10],
            "started_at": r["started_at"],
            "workout_type": meta.get("workout_type", "unknown"),
            "duration_minutes": round(meta.get("duration_seconds", 0) / 60, 1),
            "distance_km": round(meta.get("total_distance_meters", 0) / 1000, 2) if meta.get("total_distance_meters") else None,
            "calories_burned": meta.get("total_energy_burned_cal"),
            "source": r.get("source_device"),
        })

    total_duration = sum(w["duration_minutes"] for w in workouts)
    types = {}
    for w in workouts:
        types[w["workout_type"]] = types.get(w["workout_type"], 0) + 1

    return {
        "period_days": days,
        "total_workouts": len(workouts),
        "total_duration_hours": round(total_duration / 60, 1),
        "by_type": types,
        "workouts": workouts,
    }


def get_daily_snapshot(date: str = "", user_id: str = "") -> dict:
    """
    Everything recorded for a specific date (YYYY-MM-DD). Defaults to today.
    Returns steps, sleep, workouts, HRV, resting HR, active energy, and all other metrics.
    """
    uid = user_id or DEFAULT_USER_ID
    if not date:
        date = datetime.now(NY).strftime("%Y-%m-%d")

    # Compute NY midnight boundaries and convert to UTC for the DB query
    day_start_ny = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=NY)
    day_end_ny = day_start_ny + timedelta(days=1)
    day_start = day_start_ny.astimezone(timezone.utc).isoformat()
    day_end = day_end_ny.astimezone(timezone.utc).isoformat()

    # Filter on started_at for both bounds. A `lte` filter on ended_at would
    # exclude point-in-time samples (steps, HRV, resting HR) where ended_at is null.
    # PostgREST range needs two filters on the same column -> list of tuples.
    resp = httpx.get(
        f"{POSTGREST}/{TABLE}",
        headers=HEADERS,
        params=[
            ("user_id", f"eq.{uid}"),
            ("started_at", f"gte.{day_start}"),
            ("started_at", f"lte.{day_end}"),
            ("order", "metric_type.asc,started_at.asc"),
            ("limit", 1000),
        ],
        timeout=30,
    )
    resp.raise_for_status()
    rows = resp.json()

    # Group by metric type
    by_type: dict[str, list[dict]] = {}
    for r in rows:
        mt = r["metric_type"]
        by_type.setdefault(mt, []).append(r)

    # Summarise key metrics
    def first_val(metric: str) -> float | None:
        return by_type[metric][0]["value"] if metric in by_type else None

    def sum_val(metric: str) -> float | None:
        vals = [r["value"] for r in by_type.get(metric, []) if r.get("value")]
        return round(sum(vals), 0) if vals else None

    return {
        "date": date,
        "total_records": len(rows),
        "metrics_present": sorted(by_type.keys()),
        "highlights": {
            "steps": sum_val(STEPS),
            "active_energy_cal": sum_val(ACTIVE_ENERGY),
            "resting_hr_bpm": first_val(RESTING_HR),
            "hrv_sdnn_ms": first_val(HRV),
            "weight_kg": first_val(WEIGHT),
        },
        "workouts": [
            {
                "type": r.get("metadata", {}).get("workout_type"),
                "duration_minutes": round(r.get("metadata", {}).get("duration_seconds", 0) / 60, 1),
                "calories": r.get("metadata", {}).get("total_energy_burned_cal"),
            }
            for r in by_type.get(WORKOUT, [])
        ],
        "sleep_records": len(by_type.get(SLEEP, [])),
        "all_metrics": {
            mt: [{"value": r["value"], "unit": r.get("unit"), "at": r["started_at"]} for r in records]
            for mt, records in by_type.items()
        },
    }


def _get_summaries(metric_type: str, user_id: str, since_date: str, limit: int = 500) -> list[dict]:
    """Query daily summaries table for historical data."""
    resp = httpx.get(
        f"{POSTGREST}/{SUMMARY_TABLE}",
        headers=HEADERS,
        params={
            "user_id": f"eq.{user_id}",
            "metric_type": f"eq.{metric_type}",
            "date": f"gte.{since_date}",
            "order": "date.desc",
            "limit": limit,
        },
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def get_long_term_trend(
    metric_type: str,
    months: int = 24,
    user_id: str = "",
) -> dict:
    """
    Long-term trend for any metric. Tier-aware: merges recent raw data (last 30 days,
    aggregated to daily) with historical daily summaries, so the trend has no recency gap.
    Best for multi-year / seasonal analysis.
    metric_type examples: HKQuantityTypeIdentifierHeartRateVariabilitySDNN,
                          HKQuantityTypeIdentifierRestingHeartRate,
                          HKQuantityTypeIdentifierBodyMass,
                          HKQuantityTypeIdentifierStepCount
    months: how many months of history to return (default 24)
    """
    uid = user_id or DEFAULT_USER_ID
    points = _get_tiered_daily(metric_type, uid, months * 30)
    if not points:
        return {"metric_type": metric_type, "months": months, "data": [],
                "note": "No data found for this metric/window"}

    # Monthly buckets — weighted by sample_count for an exact monthly mean
    monthly: dict[str, list[dict]] = {}
    for p in points:
        monthly.setdefault(p["date"][:7], []).append(p)

    is_cumulative = metric_type in _CUMULATIVE_METRICS
    _avg_fn = _daily_total_avg if is_cumulative else _weighted_mean

    monthly_trend = [
        {"month": m, "avg": _avg_fn(pts), "days_with_data": len(pts),
         "sources": sorted({p["source"] for p in pts})}
        for m, pts in sorted(monthly.items())
    ]

    return {
        "metric_type": metric_type,
        "months_requested": months,
        "days_with_data": len(points),
        "overall_avg": _avg_fn(points),
        "overall_min": min((p["min_value"] for p in points if p.get("min_value") is not None), default=None),
        "overall_max": max((p["max_value"] for p in points if p.get("max_value") is not None), default=None),
        "monthly_trend": monthly_trend,
        "daily_data": [
            {"date": p["date"], "avg": p.get("avg_value"), "min": p.get("min_value"),
             "max": p.get("max_value"), "count": p.get("sample_count"), "source": p["source"]}
            for p in points
        ],
    }


def get_coaching_brief(user_id: str = "") -> dict:
    """
    Pre-session coaching brief for Brett — combines recent trends across all key metrics.
    Returns a structured summary optimized for performance coaching context:
    recovery status, sleep quality, training load, and fitness trajectory.
    Call this at the start of every coaching session.
    """
    uid = user_id or DEFAULT_USER_ID

    # Recent raw data (last 14 days)
    since_14d = _since(14)
    since_30d = _since(30)
    since_7d = _since(7)

    hrv_14d = _get(HRV, uid, since_14d, limit=200)
    rhr_14d = _get(RESTING_HR, uid, since_14d, limit=50)
    sleep_14d = _get(SLEEP, uid, since_14d, limit=500, source_filter="Oura")
    workouts_30d = _get(WORKOUT, uid, since_30d, limit=50)
    steps_7d = _get(STEPS, uid, since_7d, limit=500)
    vo2_rows = _get(VO2MAX, uid, _since(365), limit=50)
    weight_rows = _get(WEIGHT, uid, since_30d, limit=30)
    energy_7d = _get(ACTIVE_ENERGY, uid, since_7d, limit=500)

    def avg(rows: list[dict]) -> float | None:
        vals = [r["value"] for r in rows if r.get("value") is not None]
        return round(sum(vals) / len(vals), 1) if vals else None

    def latest(rows: list[dict]) -> float | None:
        for r in rows:
            if r.get("value") is not None:
                return r["value"]
        return None

    # HRV trend: last 7d vs prior 7d
    hrv_recent = [r["value"] for r in hrv_14d[:7] if r.get("value")]
    hrv_prior = [r["value"] for r in hrv_14d[7:] if r.get("value")]
    hrv_delta = None
    hrv_status = "unknown"
    if hrv_recent and hrv_prior:
        delta = round(sum(hrv_recent)/len(hrv_recent) - sum(hrv_prior)/len(hrv_prior), 1)
        hrv_delta = delta
        hrv_status = "improving" if delta > 2 else "declining" if delta < -2 else "stable"

    # Sleep: sum Core+Deep+REM segments only (value 3/4/5).
    # Excluding InBed (0), AsleepUnspecified (1), and Awake (2) prevents double-counting
    # when both Apple Watch and iPhone write overlapping parent records for the same night.
    nights: dict[str, float] = {}
    for row in sleep_14d:
        if row.get("value") not in (3.0, 4.0, 5.0):
            continue
        if not row.get("ended_at"):
            continue
        start = datetime.fromisoformat(row["started_at"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(row["ended_at"].replace("Z", "+00:00"))
        night_key = (start - timedelta(hours=6)).strftime("%Y-%m-%d")
        nights[night_key] = nights.get(night_key, 0) + (end - start).total_seconds() / 3600

    recent_nights = sorted(nights.items(), reverse=True)[:7]
    avg_sleep_h = round(sum(h for _, h in recent_nights) / len(recent_nights), 1) if recent_nights else None

    # Training load
    workout_types = {}
    total_workout_min = 0
    for w in workouts_30d:
        meta = w.get("metadata") or {}
        wtype = meta.get("workout_type", "unknown")
        workout_types[wtype] = workout_types.get(wtype, 0) + 1
        total_workout_min += meta.get("duration_seconds", 0) / 60

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "recovery": {
            "hrv_latest_ms": latest(hrv_14d),
            "hrv_7d_avg_ms": avg(hrv_14d[:7]) if hrv_14d else None,
            "hrv_trend": hrv_status,
            "hrv_delta_vs_prior_week_ms": hrv_delta,
            "resting_hr_latest_bpm": latest(rhr_14d),
            "resting_hr_7d_avg_bpm": avg(rhr_14d),
            "coaching_note": (
                "Good recovery — normal or increased training load appropriate" if hrv_status == "improving"
                else "Recovery declining — prioritize sleep, reduce intensity if trend continues" if hrv_status == "declining"
                else "Recovery stable"
            ),
        },
        "sleep": {
            "avg_hours_last_7_nights": avg_sleep_h,
            "nights_tracked": len(recent_nights),
            "quality_flag": (
                "good" if avg_sleep_h and avg_sleep_h >= 7.5
                else "borderline" if avg_sleep_h and avg_sleep_h >= 6.5
                else "poor" if avg_sleep_h
                else "no data"
            ),
        },
        "training_load_30d": {
            "total_workouts": len(workouts_30d),
            "total_hours": round(total_workout_min / 60, 1),
            "weekly_avg_workouts": round(len(workouts_30d) / 4.3, 1),
            "by_type": workout_types,
        },
        "activity_7d": {
            "avg_daily_steps": _avg_daily_total_from_raw(steps_7d),
            "avg_active_energy_cal": _avg_daily_total_from_raw(energy_7d),
        },
        "fitness_markers": {
            "vo2max_latest": latest(vo2_rows),
            "weight_kg_latest": latest(weight_rows),
            "weight_kg_30d_ago": weight_rows[-1]["value"] if len(weight_rows) > 1 else None,
        },
    }
