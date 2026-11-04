"""Tool arguments an AI client sends are normalised before they reach a query.

Why (2026-11-03): compare_periods and get_daily_snapshot validated dates with strptime, which
also accepts unpadded dates (2026-9-1), then compared them as strings to pick a storage tier.
"2026-9-1" sorts after "2026-10-03", so an unpadded September period in compare_periods read no
summaries and came back empty ("insufficient data" for a month that had data), and
get_daily_snapshot skipped the summary fallback for an old day. get_workouts and get_sleep
passed `days` (and get_workouts `limit`) through unclamped, unlike the other tools that take
them, so a large `days` raised OverflowError and a large `limit` fetched without a ceiling.

No database is touched: every fetch helper is replaced with an in-memory stub.
"""
import os
import pathlib
import sys
from datetime import date, datetime, timedelta, timezone

import pytest

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402


def _summary_per_day(_metric, _uid, start: str, end: str) -> list[dict]:
    # Postgres reads '2026-9-1' as a date too, so parse leniently, as the database does.
    day = datetime.strptime(start, "%Y-%m-%d").date()
    last = datetime.strptime(end, "%Y-%m-%d").date()
    rows = []
    while day <= last:
        rows.append({"date": day, "unit": "count", "sum_value": 1000.0, "avg_value": 1000.0,
                     "min_value": 1000.0, "max_value": 1000.0, "sample_count": 1})
        day += timedelta(days=1)
    return rows


def test_compare_periods_unpadded_dates_cover_the_same_days(monkeypatch):
    # Today 2026-11-03, so all of September is older than the raw cutoff and comes from summaries.
    monkeypatch.setattr(tools, "_today_local", lambda: date(2026, 11, 3))
    monkeypatch.setattr(tools, "_fetch_summaries_range", _summary_per_day)
    monkeypatch.setattr(tools, "_fill_days_from_raw", lambda *a, **k: None)
    monkeypatch.setattr(tools, "_fetch_metrics_range", lambda *a, **k: [])
    monkeypatch.setattr(tools, "_absence_note", lambda *a, **k: None)

    out = tools.compare_periods(tools.STEPS, "2026-9-1", "2026-9-30", "2026-09-01", "2026-09-30")

    # September has 30 days, whichever way its dates are written.
    assert out["Period A"]["data_points"] == 30
    assert out["Period B"]["data_points"] == 30
    assert out["Period A"]["start"] == "2026-09-01"
    assert out["Period A"]["end"] == "2026-09-30"


def _old_day_whose_unpadded_form_sorts_after_the_cutoff() -> tuple[date, str]:
    # get_daily_snapshot reads today from the real clock, so pick the input from it: an old day
    # whose unpadded form, compared as a string, lands on the wrong side of the raw cutoff.
    # One exists within a year of any cutoff (a month 2-9 against 10-12, or any month against 01-09).
    cutoff = datetime.now(timezone.utc).date() - timedelta(days=tools.RAW_CUTOFF_DAYS)
    day = cutoff - timedelta(days=1)
    while f"{day.year}-{day.month}-{day.day}" < cutoff.isoformat():
        day -= timedelta(days=1)
    return day, f"{day.year}-{day.month}-{day.day}"


def test_get_daily_snapshot_unpadded_old_date_falls_back_to_summaries(monkeypatch):
    day, unpadded = _old_day_whose_unpadded_form_sorts_after_the_cutoff()
    # Raw rows for an old day are compacted away; only its daily summary is left.
    monkeypatch.setattr(tools, "_fetch_metrics_snapshot", lambda *a, **k: [])
    monkeypatch.setattr(tools, "_fetch_summaries_range",
                        lambda metric, *_a: [{"sum_value": 4321.0, "avg_value": 4321.0}]
                        if metric == tools.STEPS else [])

    out = tools.get_daily_snapshot(unpadded)

    assert out["date"] == day.isoformat()
    assert out["highlights"]["steps"] == 4321.0


@pytest.mark.parametrize("days, limit, want_days, want_limit", [
    (1_000_000, 1_000_000, tools.MAX_DAYS, tools.MAX_LIMIT),
    (0, 0, 1, 1),
])
def test_get_workouts_clamps_days_and_limit(monkeypatch, days, limit, want_days, want_limit):
    seen = {}

    def fetch(_metric, _uid, since, limit=500, **_kw):
        seen["since"], seen["limit"] = since, limit
        return []

    monkeypatch.setattr(tools, "_fetch_metrics", fetch)

    tools.get_workouts(days=days, limit=limit)

    assert seen["limit"] == want_limit
    expected = datetime.now(timezone.utc) - timedelta(days=want_days)
    assert abs(datetime.fromisoformat(seen["since"]) - expected) < timedelta(minutes=1)


@pytest.mark.parametrize("days, want_days", [(1_000_000, tools.MAX_DAYS), (0, 1)])
def test_get_sleep_clamps_days(monkeypatch, days, want_days):
    seen = {}

    def fetch(_metric, _uid, since, limit=500, **_kw):
        seen["since"] = since
        return []

    monkeypatch.setattr(tools, "_fetch_metrics", fetch)

    tools.get_sleep(days=days)

    expected = datetime.now(timezone.utc) - timedelta(days=want_days)
    assert abs(datetime.fromisoformat(seen["since"]) - expected) < timedelta(minutes=1)
