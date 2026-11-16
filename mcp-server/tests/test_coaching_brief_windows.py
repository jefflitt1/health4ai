"""get_coaching_brief's numbers must mean what their names say.

Why (2026-10-20): "hrv_7d_avg_ms" averaged the 7 most recent HRV samples (an hour or two for a
tracker that writes several a night) and "resting_hr_7d_avg_bpm" averaged up to 14 days; the
HRV trend compared 7 samples with the rest. "weight_kg_*" passed raw values through whatever
their unit, so a reading stored in grams came out as 72650 kg. Steps and active energy were
fetched row by row (up to 100k rows) only to be summed per day.

No database is touched: the fetch helpers are replaced with in-memory stubs.
"""
import os
import pathlib
import sys
from datetime import datetime, timedelta, timezone
import pytest

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402

NOW = datetime(2026, 11, 16, 10, tzinfo=timezone.utc)


@pytest.fixture(autouse=True)
def fixed_clock(monkeypatch):
    # Keep the fresh fixture before noon, after the preceding night's sleep.
    monkeypatch.setattr(tools, "_now", lambda: NOW)
    monkeypatch.setattr(tools, "TZ", timezone.utc)
    monkeypatch.setattr(tools, "TZ_NAME", "UTC")


def _row(hours_ago: float, value: float, unit: str = "") -> dict:
    return {"started_at": (NOW - timedelta(hours=hours_ago)).isoformat(), "value": value, "unit": unit}


def _brief(monkeypatch, rows_by_metric: dict, daily_totals: dict | None = None, calls: list | None = None):
    def fetch(metric_type, user_id, since, limit=500, source_filter=None):
        if calls is not None:
            calls.append((metric_type, limit))
        rows = [r for r in rows_by_metric.get(metric_type, []) if r["started_at"] >= since]
        return sorted(rows, key=lambda r: r["started_at"], reverse=True)[:limit]
    monkeypatch.setattr(tools, "_fetch_metrics", fetch)
    monkeypatch.setattr(tools, "_get_tiered_daily", lambda *a, **k: [])
    def aggregates(metric_type, user_id, start_date, end_date):
        if calls is not None:
            calls.append((metric_type, start_date, end_date))
        return (daily_totals or {}).get(metric_type, [])
    monkeypatch.setattr(tools, "_fetch_raw_daily_aggregates", aggregates)
    return tools.get_coaching_brief()


def test_hrv_and_resting_hr_cover_seven_days_not_seven_samples(monkeypatch):
    # Ten 60 ms samples in the last two days, five 40 ms samples ten days ago.
    hrv = [_row(4 * i + 1, 60.0, "ms") for i in range(10)] + [_row(240 + i, 40.0, "ms") for i in range(5)]
    # Resting HR 50 on each of the last 7 days, 60 on each of the 7 days before.
    rhr = [_row(24 * d + 3, 50.0) for d in range(7)] + [_row(24 * d + 3, 60.0) for d in range(7, 13)]
    out = _brief(monkeypatch, {tools.HRV: hrv, tools.RESTING_HR: rhr})
    assert out["recovery"]["hrv_7d_avg_ms"] == 60.0
    assert out["recovery"]["hrv_delta_vs_prior_week_ms"] == 20.0
    assert out["recovery"]["hrv_trend"] == "improving"
    assert out["recovery"]["resting_hr_7d_avg_bpm"] == 50.0


def test_no_hrv_in_the_last_seven_days_is_said_so(monkeypatch):
    out = _brief(monkeypatch, {tools.HRV: [_row(240, 40.0, "ms")], tools.RESTING_HR: [_row(200, 55.0)]})
    assert out["recovery"]["hrv_7d_avg_ms"] is None
    assert out["recovery"]["hrv_latest_ms"] is None  # the 10-day-old reading is not "latest"
    assert out["recovery"]["resting_hr_latest_bpm"] is None
    assert out["recovery"]["hrv_trend"] == "unknown"
    assert "no hrv samples in the last 7 days" in out["recovery"]["coaching_note"].lower()


def test_weight_is_reported_in_kilograms_whatever_its_unit(monkeypatch):
    weight = [_row(1, 72650.0, "g"), _row(50, 160.0, "lb"), _row(60, 1.0, "furlong"), _row(100, 72.4, "kg")]
    no_unit = _brief(monkeypatch, {tools.WEIGHT: [{**_row(1, 71.0), "unit": None}]})
    assert no_unit["fitness_markers"]["weight_kg_latest"] == 71.0  # the app writes kg
    out = _brief(monkeypatch, {tools.WEIGHT: weight})
    assert out["fitness_markers"]["weight_kg_latest"] == 72.65
    assert out["fitness_markers"]["weight_kg_30d_ago"] == 72.4  # the oldest convertible reading
    lb = _brief(monkeypatch, {tools.WEIGHT: [_row(1, 160.0, "lb"), _row(2, 11.0, "st")]})
    assert lb["fitness_markers"]["weight_kg_latest"] == 72.57  # 160 lb = 72.5747792 kg
    assert lb["fitness_markers"]["weight_kg_30d_ago"] == 69.85  # 11 st = 69.85322498 kg


def test_steps_and_energy_are_summed_in_sql_over_seven_whole_days(monkeypatch):
    calls: list = []
    days = [{"date": f"2026-10-{d:02d}", "unit": "count", "sum_value": 1000.0 * d, "sample_count": 24,
             "source": "raw"} for d in (14, 15, 16)]
    newest = NOW - timedelta(hours=1)
    steps = [_row(h, 10.0, "count") for h in (30, 5, 1)]
    before = tools._today_local()
    out = _brief(monkeypatch, {tools.STEPS: steps}, {tools.STEPS: days}, calls)
    after = tools._today_local()
    row_fetches = [c for c in calls if len(c) == 2]
    # Step rows are read only for freshness, one row; energy rows not at all.
    assert [c for c in row_fetches if c[0] in (tools.STEPS, tools.ACTIVE_ENERGY)] == [(tools.STEPS, 1)]
    # The week is today-7..today-1; read before and after the call in case it spans midnight.
    weeks = {((d - timedelta(days=7)).isoformat(), (d - timedelta(days=1)).isoformat()) for d in (before, after)}
    assert any((tools.STEPS, *w) in calls and (tools.ACTIVE_ENERGY, *w) in calls for w in weeks)
    assert out["activity_7d"]["avg_daily_steps"] == 15000.0
    assert out["activity_7d"]["avg_active_energy_cal"] is None
    # The newest step still counts towards freshness.
    assert out["data_status"]["status"] == "fresh"
    assert out["data_status"]["newest_sample_at"] == newest.isoformat()


def _night(hours_ago_start: float, hours: float) -> dict:
    start = NOW - timedelta(hours=hours_ago_start)
    return {"started_at": start.isoformat(), "ended_at": (start + timedelta(hours=hours)).isoformat(),
            "value": 3.0, "unit": "", "source_device": "Apple Watch"}


def test_sleep_averages_only_nights_that_ended_in_the_last_seven_days(monkeypatch):
    # Seven 8-hour nights 8 to 13 days ago, then nothing tracked: no sleep this week.
    old = [_night(24 * d, 8.0) for d in range(8, 14)] + [_night(24 * 7 + 20, 8.0)]
    stale = _brief(monkeypatch, {tools.SLEEP: old})
    assert stale["sleep"]["nights_tracked"] == 0
    assert stale["sleep"]["avg_hours_last_7_nights"] is None
    # Add one 6-hour night that ended 2 hours ago: only it counts.
    fresh = _brief(monkeypatch, {tools.SLEEP: old + [_night(8, 6.0)]})
    assert fresh["sleep"]["nights_tracked"] == 1
    assert fresh["sleep"]["avg_hours_last_7_nights"] == 6.0


def test_description_names_no_one():
    assert "Brett" not in tools.get_coaching_brief.__doc__
