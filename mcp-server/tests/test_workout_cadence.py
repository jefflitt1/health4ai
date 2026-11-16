"""Pure derivation boundaries: exact association does not imply complete cadence."""
from copy import deepcopy
from datetime import datetime, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo
import pathlib
import sys

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from health4ai.workout_cadence import derive_step_cadence


def sample(**fields):
    return {"sample_uuid": "00000000-0000-4000-8000-000000000001",
            "metric_type": "HKQuantityTypeIdentifierStepCount", "value": 180,
            "unit": "count", "source_device": "Watch",
            "started_at": "2026-11-16T12:00:00Z", "ended_at": "2026-11-16T12:01:00Z",
            **fields}


def derive(row):
    return derive_step_cadence(row, exact_workout_association=True)


def test_rate_is_interval_mean_with_explicit_provenance():
    result = derive(sample(value=90))
    assert result["value"] == 90
    assert result["unit"] == "steps/min"
    assert result["duration_seconds"] == 60
    assert result["source_sample_uuid"] == sample()["sample_uuid"]
    assert result["interpretation"] == "sample_interval_mean_not_recorded_or_instantaneous_cadence"
    assert result["coverage"] == "this_source_sample_interval_only"
    assert result["workout_average"] is None


def test_seconds_are_converted_to_minutes():
    assert derive(sample(value=45, ended_at="2026-11-16T12:00:15Z"))["value"] == 180


def test_absent_association_never_inferred_from_timestamps():
    assert derive_step_cadence(sample())["reason"] == "exact_workout_association_required"
    assert derive_step_cadence(sample(), exact_workout_association=1)["status"] == "unavailable"


@pytest.mark.parametrize("value", [None, True, "180", -1, float("nan"), float("inf"), Decimal("NaN"), 10**400])
def test_invalid_step_counts(value):
    assert derive(sample(value=value))["reason"] == "invalid_step_count"


@pytest.mark.parametrize("unit", [None, "steps/min", "steps/s", "m", ""])
def test_no_implicit_unit_conversion(unit):
    assert derive(sample(unit=unit))["reason"] == "unsupported_step_unit"


@pytest.mark.parametrize("end", ["2026-11-16T12:00:00Z", "2026-11-16T11:59:00Z"])
def test_zero_or_negative_duration(end):
    assert derive(sample(ended_at=end))["reason"] == "positive_sample_duration_required"


@pytest.mark.parametrize("end", [None, "invalid", "2026-11-16T12:01:00", "0001-01-01T00:00:00+14:00"])
def test_missing_invalid_or_naive_time(end):
    assert derive(sample(ended_at=end))["reason"] == "timezone_aware_interval_required"


def test_timezone_offsets_and_database_datetime_agree():
    row = sample(started_at="2026-11-16T07:00:00-05:00",
                 ended_at=datetime(2026, 11, 16, 12, 1, tzinfo=timezone.utc), value=Decimal("180"))
    assert derive(row)["value"] == 180


def test_fall_back_interval_uses_elapsed_not_wall_clock_time():
    zone = ZoneInfo("America/New_York")
    row = sample(started_at=datetime(2026, 11, 1, 1, 0, tzinfo=zone, fold=0),
                 ended_at=datetime(2026, 11, 1, 1, 0, tzinfo=zone, fold=1), value=180)
    assert derive(row)["duration_seconds"] == 3600
    assert derive(row)["value"] == 3


def test_zero_is_valid_observed_count_not_missing_data():
    assert derive(sample(value=0))["value"] == 0
    assert derive({}) == {"status": "not_applicable", "reason": "not_step_count"}


def test_duplicate_or_overlapping_samples_never_form_combined_rate():
    row = sample()
    before = deepcopy(row)
    results = [derive(row), derive(row), derive(sample(source_device="Phone", value=60))]
    assert [r["value"] for r in results] == [180, 180, 60]
    assert all(r["workout_average"] is None for r in results)
    assert results[0]["source_sample_uuid"] == results[1]["source_sample_uuid"]
    assert row == before  # Caller retains original IDs to recognize duplicates.


def test_pause_duration_is_not_subtracted_or_guessed():
    result = derive(sample(value=180, ended_at="2026-11-16T12:02:00Z", pause_seconds=60))
    assert result["value"] == 90
    assert result["pause_adjustment"] == "none_elapsed_time_includes_any_pauses"


def test_bad_uuid_and_overflowing_rate_are_explicit():
    assert derive(sample(sample_uuid=""))["reason"] == "invalid_sample_uuid"
    assert derive(sample(value=1e308, ended_at="2026-11-16T12:00:00.000001Z"))["reason"] == "nonfinite_derived_rate"
