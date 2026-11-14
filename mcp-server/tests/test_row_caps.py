"""Aggregates over a raw window (30 days or less) must not silently lose rows to a fixed row cap.

Why (2026-11-03): steps sync as one merged row per hour, so get_health_summary's default 500-row
fetch held only ~21 days and under-reported a 30-day total by about 30%. get_coaching_brief had
fixed caps on sleep (500; two sleep trackers write ~140 stage rows a night), steps (500), active
energy (500), workouts (50), resting HR (50), weight (30) and HRV (200). get_sleep stopped at 1000
rows (about 7 nights from two trackers) and cut the oldest night at the window edge.

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


# get_sleep tests run on a fixed clock in UTC, whenever the suite runs and whatever HEALTH4AI_TZ
# is set to. No fixture night spans 06:00 or noon, so none is split between two night dates.
T0 = datetime(2026, 3, 20, 3, 0, tzinfo=timezone.utc)


def _fixed_clock(monkeypatch):
    monkeypatch.setattr(tools, "_since", lambda days: _iso(T0 - timedelta(days=days)))
    monkeypatch.setattr(tools, "TZ", timezone.utc)


def _ten_nights_two_trackers() -> list[dict]:
    # Bed at 20:00 UTC on each of the 10 days before T0, 70 five-minute stages per tracker.
    rows = []
    for n in range(1, 11):
        bedtime = (T0 - timedelta(days=n)).replace(hour=20)
        rows += _night("Oura Ring", bedtime, 70) + _night("Apple Watch", bedtime, 70)
    return rows


def test_sleep_keeps_every_night_of_two_trackers(monkeypatch):
    # 1400 rows; the old cap of 1000 dropped the oldest nights.
    _fixed_clock(monkeypatch)
    _stub(monkeypatch, {tools.SLEEP: _ten_nights_two_trackers()})
    out = tools.get_sleep(14)
    assert len(out["nights"]) == 10
    assert {n["source"] for n in out["nights"]} == {"Oura Ring"}
    assert [n["total_minutes"] for n in out["nights"]] == [350.0] * 10


def test_a_night_across_the_window_edge_is_counted_whole(monkeypatch):
    # The 7-day window starts 2026-03-13 03:00 UTC; this night runs 23:00 to 05:00.
    _fixed_clock(monkeypatch)
    _stub(monkeypatch, {tools.SLEEP: _night("Oura Ring", datetime(2026, 3, 12, 23, 0, tzinfo=timezone.utc), 72)})
    out = tools.get_sleep(7)
    assert [n["total_minutes"] for n in out["nights"]] == [360.0]


def test_a_night_that_ended_before_the_window_is_not_counted(monkeypatch):
    # Runs 21:00 to 02:30 UTC, half an hour before the window starts.
    _fixed_clock(monkeypatch)
    _stub(monkeypatch, {tools.SLEEP: _night("Oura Ring", datetime(2026, 3, 12, 21, 0, tzinfo=timezone.utc), 66)})
    assert tools.get_sleep(7)["nights"] == []


def test_at_the_row_cap_the_possibly_partial_oldest_night_is_dropped(monkeypatch):
    _fixed_clock(monkeypatch)
    monkeypatch.setattr(tools, "RAW_WINDOW_LIMIT", 300)  # 2 whole nights (280 rows) and 20 of a third
    _stub(monkeypatch, {tools.SLEEP: _ten_nights_two_trackers()})
    out = tools.get_sleep(14)
    assert [n["total_minutes"] for n in out["nights"]] == [350.0, 350.0]
    # The two whole nights began at 20:00 UTC on March 19 and 18, so the listed nights start on
    # March 18, not 14 days before T0.
    assert out["covered_since"] == "2026-03-18"
    assert "coverage_note" in out


def test_long_windows_list_segments_only_for_recent_nights(monkeypatch):
    _fixed_clock(monkeypatch)
    _stub(monkeypatch, {tools.SLEEP: _ten_nights_two_trackers()})
    out = tools.get_sleep(14)
    # Night n ends 1 h 10 min before T0 minus n-1 days, so nights 1-7 ended in the last 7 days.
    assert len(out["nights"]) == 10
    assert all(len(n["segments"]) == 70 for n in out["nights"][:7])
    assert not any("segments" in n for n in out["nights"][7:])
    assert all(n["total_minutes"] == 350.0 for n in out["nights"])
    assert "segments_note" in out
    assert "covered_since" not in out and "coverage_note" not in out


def test_seven_day_window_lists_every_night_with_segments(monkeypatch):
    # Nights 1-7, plus one that began before the window edge and ended inside it: 8 nights.
    _fixed_clock(monkeypatch)
    edge = _night("Oura Ring", datetime(2026, 3, 12, 23, 0, tzinfo=timezone.utc), 72)
    _stub(monkeypatch, {tools.SLEEP: _ten_nights_two_trackers() + edge})
    out = tools.get_sleep(7)
    assert len(out["nights"]) == 8
    assert all("segments" in n for n in out["nights"])
    assert "segments_note" not in out


def test_thirty_day_summary_counts_every_hourly_step_row(monkeypatch):
    # 720 merged hourly rows of 10 steps, all inside the 30-day window.
    steps = [{"started_at": _iso(NOW - timedelta(hours=h, minutes=30)), "value": 10.0, "unit": "count"}
             for h in range(720)]
    _stub(monkeypatch, {tools.STEPS: steps})
    out = tools.get_health_summary(30)
    assert out["steps"]["total"] == 7200.0
    assert out["steps"]["days_with_data"] >= 30


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
