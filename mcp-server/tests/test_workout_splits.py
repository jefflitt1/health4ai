"""Derived route splits (#54): distance from consecutive GPS points, never inferred."""
import os
import pathlib
import sys
import uuid
from datetime import datetime, timedelta, timezone

import pytest

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import tools  # noqa: E402
from health4ai import workout_routes  # noqa: E402
from health4ai.workout_splits import EARTH_RADIUS_M, compute_splits  # noqa: E402

START = datetime(2026, 11, 15, 12, 0, tzinfo=timezone.utc)
ROUTE = str(uuid.UUID(int=1))
M_PER_DEG = EARTH_RADIUS_M * 3.141592653589793 / 180


def line(total_m, speed=3.0, step_s=10, pause=None, altitude=None):
    """Points due north at `speed` m/s; `pause` = (start_s, end_s) standing still."""
    points, t, d = [], 0, 0.0
    while True:
        alt = altitude(d) if altitude else None
        points.append({"route_uuid": ROUTE, "point_index": len(points),
                       "timestamp": START + timedelta(seconds=t), "latitude": d / M_PER_DEG,
                       "longitude": 0.0, "altitude": alt, "horizontal_accuracy": 5.0,
                       "vertical_accuracy": 3.0 if alt is not None else -1.0})
        if d >= total_m - 1e-9:
            return points
        nxt = min(total_m, d + speed * step_s)
        paused_next = pause and pause[0] < t + step_s <= pause[1]
        t += step_s if paused_next else (nxt - d) / speed  # constant speed, even on the last step
        if paused_next:
            continue
        d = nxt


def event(kind, seconds):
    at = (START + timedelta(seconds=seconds)).isoformat()
    return {"type": kind, "started_at": at, "ended_at": at, "duration_seconds": 0}


def test_straight_line_km_splits_with_partial():
    result = compute_splits(line(3500), unit="km", events=[], events_truncated=False)
    splits = result["splits"]
    assert [s["partial"] for s in splits] == [False, False, False, True]
    for s in splits[:3]:
        assert s["distance_m"] == pytest.approx(1000, abs=0.5)
        assert s["elapsed_seconds"] == pytest.approx(1000 / 3, abs=0.5)
        assert s["pace_seconds_per_unit"] == pytest.approx(1000 / 3, abs=0.5)
    assert splits[3]["distance_m"] == pytest.approx(500, abs=0.5)
    assert splits[3]["pace_seconds_per_unit"] == pytest.approx(1000 / 3, abs=0.5)
    assert result["total_distance_m"] == pytest.approx(3500, abs=1)
    assert result["time_basis"] == "moving_excluding_recorded_pauses"


def test_mile_splits_interpolate_boundary():
    splits = compute_splits(line(3500), unit="mi", events=[], events_truncated=False)["splits"]
    assert len(splits) == 3 and splits[-1]["partial"]
    assert splits[0]["distance_m"] == pytest.approx(1609.344, abs=0.5)
    assert splits[0]["elapsed_seconds"] == pytest.approx(1609.344 / 3, abs=0.5)


def test_recorded_pause_is_excluded():
    points = line(1500, pause=(150, 270))
    events = [event("pause", 150), event("resume", 270)]
    result = compute_splits(points, unit="km", events=events, events_truncated=False)
    assert result["time_basis"] == "moving_excluding_recorded_pauses"
    assert result["splits"][0]["elapsed_seconds"] == pytest.approx(1000 / 3, abs=0.5)


def test_unknown_events_count_pause_time_and_say_so():
    points = line(1500, pause=(150, 270))
    for events, truncated in ((None, None), ([event("pause", 150)], True)):
        result = compute_splits(points, unit="km", events=events, events_truncated=truncated)
        assert result["time_basis"] == "elapsed_including_pauses"
        assert result["splits"][0]["elapsed_seconds"] == pytest.approx(1000 / 3 + 120, abs=0.5)


def test_route_under_one_unit_is_a_single_partial_split():
    splits = compute_splits(line(400), unit="km", events=[], events_truncated=False)["splits"]
    assert len(splits) == 1 and splits[0]["partial"]
    assert splits[0]["distance_m"] == pytest.approx(400, abs=0.5)


def test_elevation_gain_and_loss_when_altitude_present():
    up_then_down = lambda d: d / 100 if d <= 1000 else 10 - (d - 1000) / 100  # noqa: E731
    splits = compute_splits(line(2000, altitude=up_then_down), unit="km",
                            events=[], events_truncated=False)["splits"]
    assert splits[0]["elevation_gain_m"] == pytest.approx(10, abs=0.5)
    assert splits[1]["elevation_loss_m"] == pytest.approx(10, abs=0.5)
    flat = compute_splits(line(1000), unit="km", events=[], events_truncated=False)["splits"]
    assert flat[0]["elevation_gain_m"] is None


def test_imprecise_points_are_skipped_and_counted():
    points = line(1000)
    points[5]["horizontal_accuracy"] = 500.0
    points[5]["longitude"] = 1.0  # a 111 km jump that must not count
    result = compute_splits(points, unit="km", events=[], events_truncated=False)
    assert result["total_distance_m"] == pytest.approx(1000, abs=1)
    assert result["points_skipped_low_accuracy"] == 1


def test_overlapping_manual_and_motion_pauses_subtracted_once():
    # One 10 s, 30 m segment with a manual pause 2-6 s and a motion pause 3-5 s inside it:
    # 4 s paused and 6 s moving, not 6 s paused.
    points = line(30, step_s=10)
    assert len(points) == 2
    events = [event("pause", 2), event("motion_paused", 3),
              event("motion_resumed", 5), event("resume", 6)]
    result = compute_splits(points, unit="km", events=events, events_truncated=False)
    assert result["splits"][0]["elapsed_seconds"] == pytest.approx(6, abs=0.05)


def _second_route(points, route, lon_offset_deg=0.0, shift_s=0):
    return [dict(p, route_uuid=route, longitude=p["longitude"] + lon_offset_deg,
                 timestamp=p["timestamp"] + timedelta(seconds=shift_s)) for p in points]


def test_routes_sharing_timestamps_are_not_interleaved():
    # Two recordings of the same 600 m at the same times (two devices): counted once, not
    # zeroed by alternating between routes.
    first = line(600)
    second = _second_route(first, str(uuid.UUID(int=2)), lon_offset_deg=0.00001)
    result = compute_splits(first + second, unit="km", events=[], events_truncated=False)
    assert result["total_distance_m"] == pytest.approx(600, abs=1)
    assert result["splits"][0]["elapsed_seconds"] == pytest.approx(200, abs=0.5)


def test_gap_between_routes_is_not_moving_time():
    # 600 m, a 10 minute gap with no route (no pause events), then another 600 m.
    first = line(600)
    second = _second_route(line(600), str(uuid.UUID(int=2)), shift_s=200 + 600)
    result = compute_splits(first + second, unit="km", events=[], events_truncated=False)
    assert result["total_distance_m"] == pytest.approx(1200, abs=1)
    assert result["splits"][0]["elapsed_seconds"] == pytest.approx(1000 / 3, abs=0.5)
    assert result["splits"][1]["elapsed_seconds"] == pytest.approx(200 / 3, abs=0.5)


def test_invalid_unit_rejected():
    with pytest.raises(ValueError):
        compute_splits(line(100), unit="furlong", events=[], events_truncated=False)


class _Cursor:
    def __init__(self, export, points, workout_rows):
        self.export, self.points, self.workout_rows, self.result = export, points, workout_rows, None

    def execute(self, sql, params=None):
        if "route_exports" in sql:
            self.result = [self.export]
        elif "route_points" in sql:
            self.result = list(self.points)[: params[-1]]
        elif "healthkit_metrics" in sql:
            self.result = self.workout_rows
        else:
            self.result = []

    def fetchone(self):
        return self.result[0] if self.result else None

    def fetchall(self):
        return self.result

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class _Conn:
    def __init__(self, cursor):
        self._cursor = cursor

    def cursor(self, **kw):
        return self._cursor

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _wire(monkeypatch, points, workout_rows):
    user = str(uuid.UUID(int=7))
    monkeypatch.setenv("HEALTH4AI_WORKOUT_ROUTES_ENABLED", "true")
    monkeypatch.setattr(tools, "validate_user_id", lambda u: user)
    export = {"export_uuid": str(uuid.UUID(int=9)), "routes": [], "invalid_counts": None}
    cursor = _Cursor(export, points, workout_rows)
    monkeypatch.setattr(tools, "_connect", lambda: _Conn(cursor))


def test_get_workout_routes_returns_whole_route_splits_on_a_small_page(monkeypatch):
    points = line(1500, pause=(150, 270))
    rows = [{"metadata": {"workout_uuid": str(uuid.UUID(int=3)), "workout_events_truncated": False,
                          "workout_events": [event("pause", 150), event("resume", 270)]}}]
    _wire(monkeypatch, points, rows)
    result = workout_routes.get_workout_routes(str(uuid.UUID(int=3)), limit=2, splits="km")
    assert len(result["points"]) == 2  # page size still honoured
    assert result["splits"]["time_basis"] == "moving_excluding_recorded_pauses"
    assert [s["partial"] for s in result["splits"]["splits"]] == [False, True]
    assert result["splits"]["total_distance_m"] == pytest.approx(1500, abs=1)


def test_get_workout_routes_without_splits_is_unchanged(monkeypatch):
    _wire(monkeypatch, line(500), [])
    result = workout_routes.get_workout_routes(str(uuid.UUID(int=3)), limit=2)
    assert "splits" not in result


def test_splits_with_cursor_rejected(monkeypatch):
    _wire(monkeypatch, line(500), [])
    with pytest.raises(ValueError):
        workout_routes.get_workout_routes(str(uuid.UUID(int=3)), cursor="abc", splits="km")
