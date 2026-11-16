"""Workout metadata reaches MCP without guessing missing events or sample links."""
import os
import pathlib
import sys

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import tools


def test_workout_events_and_completeness_reach_mcp(monkeypatch):
    events = [{"type": "lap", "type_raw": 3, "duration_seconds": 60}]
    row = {"started_at": "2026-11-15T12:00:00Z", "metadata": {
        "workout_uuid": "example-uuid", "workout_events": events,
        "workout_events_total": 40, "workout_events_truncated": True,
        "workout_type": "Running", "duration_seconds": 600,
    }}
    monkeypatch.setattr(tools, "_fetch_metrics", lambda *a, **kw: [row])
    workout = tools.get_workouts()["workouts"][0]
    assert workout["workout_uuid"] == "example-uuid"
    assert workout["events"] == events
    assert workout["events_total"] == 40
    assert workout["events_truncated"] is True
    assert workout["duration_minutes"] == 10


def test_legacy_workout_does_not_claim_no_events(monkeypatch):
    monkeypatch.setattr(tools, "_fetch_metrics", lambda *a, **kw: [
        {"started_at": "2026-11-15T12:00:00Z", "metadata": None}])
    workout = tools.get_workouts()["workouts"][0]
    for key in ("workout_uuid", "events", "events_total", "events_truncated"):
        assert workout[key] is None
