"""A capped all-metrics listing must not hide a day's key highlights."""
import os
import pathlib
import sys

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402


def test_highlights_survive_capped_all_metrics(monkeypatch):
    day = tools._today_local().isoformat()
    capped = [{"metric_type": tools.ACTIVE_ENERGY, "value": 1,
               "started_at": f"{day}T00:00:00+00:00", "unit": "kcal"}] * 1000
    calls = []
    monkeypatch.setattr(tools, "_fetch_metrics_snapshot", lambda *a, **k: capped)

    def aggregates(uid, start, end):
        calls.append((start, end))
        return {
            tools.ACTIVE_ENERGY: {"sum_value": 1000, "first_value": 1},
            tools.STEPS: {"sum_value": 0, "first_value": 0},
            tools.HRV: {"sum_value": 42, "first_value": 42},
            tools.RESTING_HR: {"sum_value": 60, "first_value": 60},
        }

    monkeypatch.setattr(tools, "_fetch_snapshot_highlights", aggregates, raising=False)
    out = tools.get_daily_snapshot(day)
    assert len(calls) == 1
    assert out["truncated"] is True
    assert len(out["all_metrics"][tools.ACTIVE_ENERGY]) == 1000
    assert out["highlights"] == {
        "steps": 0, "active_energy_cal": 1000, "resting_hr_bpm": 60,
        "hrv_sdnn_ms": 42, "weight_kg": None,
    }
    assert {tools.STEPS, tools.HRV, tools.RESTING_HR}.issubset(out["metrics_present"])


def test_highlight_query_aggregates_only_key_types_in_one_day(monkeypatch):
    seen = []

    class Cursor:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

        def execute(self, sql, params):
            seen.append((sql, params))

        def fetchall(self):
            return [{"metric_type": tools.STEPS, "sum_value": 0, "first_value": 0}]

    class Conn:
        def cursor(self, **_):
            return Cursor()

        def close(self):
            pass

    monkeypatch.setattr(tools, "_connect", Conn)
    out = tools._fetch_snapshot_highlights("u1", "start", "end")
    assert out[tools.STEPS]["sum_value"] == 0
    sql, params = seen[0]
    assert "GROUP BY metric_type" in sql
    assert "LIMIT" not in sql
    assert params[:3] == ("u1", "start", "end")
    assert set(params[3]) == {tools.STEPS, tools.ACTIVE_ENERGY, tools.RESTING_HR, tools.HRV, tools.WEIGHT}
