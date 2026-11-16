"""Aggregates over a raw window (30 days or less) must not silently lose rows to a fixed row cap.

Why (2026-11-03): steps sync as one merged row per hour, so get_health_summary's default 500-row
fetch held only ~21 days and under-reported a 30-day total by about 30%. get_coaching_brief had
fixed caps on sleep (500; two sleep trackers write ~140 stage rows a night), steps (500), active
energy (500), workouts (50), resting HR (50), weight (30) and HRV (200).

No database is touched: _fetch_metrics is replaced with a stub that honours `since` and `limit`
the way the real query does (newest first).
"""
import os
import pathlib
import sys
from datetime import datetime, timedelta, timezone

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402

NOW = datetime.now(timezone.utc)


def _stub(monkeypatch, rows_by_metric: dict):
    def fetch(metric_type, user_id, since, limit=500, source_filter=None):
        rows = [r for r in rows_by_metric.get(metric_type, []) if r["started_at"] >= since]
        rows.sort(key=lambda r: r["started_at"], reverse=True)
        return rows[:limit]
    monkeypatch.setattr(tools, "_fetch_metrics", fetch)
    monkeypatch.setattr(tools, "_absence_note", lambda *a, **k: None)
    monkeypatch.setattr(tools, "_count_sleep_rows", lambda *a, **k: (0, 0))
    monkeypatch.setattr(tools, "_count_workouts", lambda *a, **k: (0, []))


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


def _night(device: str, bedtime: datetime, segments: int) -> list[dict]:
    rows = []
    for i in range(segments):
        start = bedtime + timedelta(minutes=5 * i)
        rows.append({"started_at": _iso(start), "ended_at": _iso(start + timedelta(minutes=5)),
                     "value": 3.0, "source_device": device})
    return rows


def _two_trackers(nights: int) -> list[dict]:
    # An Oura ring and an Apple Watch, 70 five-minute stages each a night: 140 rows a night.
    rows = []
    for n in range(1, nights + 1):
        bedtime = NOW - timedelta(days=n, hours=8)
        rows += _night("Oura Ring", bedtime, 70) + _night("Apple Watch", bedtime, 70)
    return rows


def test_thirty_day_summary_counts_every_hourly_step_row(monkeypatch):
    # 720 merged hourly rows of 10 steps, all inside the 30-day window.
    steps = [{"started_at": _iso(NOW - timedelta(hours=h, minutes=30)), "value": 10.0, "unit": "count"}
             for h in range(720)]
    _stub(monkeypatch, {tools.STEPS: steps})
    out = tools.get_health_summary(30)
    assert out["steps"]["total"] == 7200.0
    assert out["steps"]["days_with_data"] >= 30


def test_summary_counts_sleep_and_workouts_in_sql_without_a_row_cap(monkeypatch):
    # Sleep and workouts are never compacted, so a 5-year window counts raw rows. Two sleep
    # trackers write ~140 rows a night: about 255,000 rows over 5 years, past any row cap. The
    # counts come from SQL, so no sleep or workout row is fetched just to be counted.
    _stub(monkeypatch, {})
    fetched = []
    real_fetch = tools._fetch_metrics
    monkeypatch.setattr(tools, "_fetch_metrics",
                        lambda metric_type, *a, **k: fetched.append(metric_type) or real_fetch(metric_type, *a, **k))
    monkeypatch.setattr(tools, "_count_sleep_rows", lambda uid, since: (255_500, 250_000))
    monkeypatch.setattr(tools, "_count_workouts", lambda uid, since: (1_200, ["cycling", "walking"]))
    monkeypatch.setattr(tools, "_get_tiered_daily", lambda *a, **k: [])
    out = tools.get_health_summary(1825)
    assert out["sleep"] == {"total_records": 255_500, "stage_records": 250_000}
    assert out["workouts"]["count"] == 1_200
    assert sorted(out["workouts"]["types"]) == ["cycling", "walking"]
    assert tools.SLEEP not in fetched and tools.WORKOUT not in fetched


def test_coaching_brief_counts_every_row_in_its_windows(monkeypatch):
    # 100 step rows of 10 on each of the last 6 local days (600 rows; the old cap was 500), 60
    # workouts in 30 days (old cap 50), two sleep trackers for a week (980 rows; old cap 500), and
    # a scale used twice a day for a month (59 rows; with the old cap of 30, "30 days ago" was
    # really 15 days ago).
    midnight = datetime.now(tools.TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    steps = [{"started_at": _iso(midnight - timedelta(days=k) + timedelta(hours=12, minutes=i)),
              "value": 10.0, "unit": "count"} for k in range(1, 7) for i in range(100)]
    workouts = [{"started_at": _iso(NOW - timedelta(hours=11 * i + 1)), "value": None,
                 "metadata": {"workout_type": "walking", "duration_seconds": 600}} for i in range(60)]
    weight = [{"started_at": _iso(NOW - timedelta(hours=12 * i + 1)), "value": 70.0 + i / 100}
              for i in range(59)]
    _stub(monkeypatch, {tools.STEPS: steps, tools.WORKOUT: workouts, tools.SLEEP: _two_trackers(7),
                        tools.WEIGHT: weight})
    monkeypatch.setattr(tools, "_get_tiered_daily", lambda *a, **k: [])
    out = tools.get_coaching_brief()
    assert out["training_load_30d"]["total_workouts"] == 60
    assert out["data_status"]["workouts_30d"] == 60
    assert out["data_status"]["sleep_rows_14d"] == 7 * 140
    assert out["sleep"]["nights_tracked"] == 7
    assert out["fitness_markers"]["weight_kg_30d_ago"] == 70.58  # the oldest of the 59 readings
    assert out["activity_7d"]["avg_daily_steps"] == 1000.0  # 100 x 10 steps on each of 6 days
