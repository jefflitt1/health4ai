"""Per-sample elapsed step rate; never recorded or instantaneous cadence."""
from datetime import datetime, timezone
from decimal import Decimal
import math
from uuid import UUID


def _instant(value):
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    if not isinstance(value, datetime) or value.utcoffset() is None:
        return None
    try:
        return value.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        return None


def derive_step_cadence(sample: dict, *, exact_workout_association: bool = False) -> dict:
    """Caller must establish HealthKit workout association, not time overlap.

    Each result covers only this source sample's elapsed interval, including any
    pauses. No source selection, clipping, interpolation, summation or deduplication
    is performed. Pagination and absent source data cannot establish workout coverage.
    """
    def unavailable(reason):
        return {"status": "unavailable", "reason": reason}

    if sample.get("metric_type") != "HKQuantityTypeIdentifierStepCount":
        return {"status": "not_applicable", "reason": "not_step_count"}
    if exact_workout_association is not True:
        return unavailable("exact_workout_association_required")
    try:
        sample_uuid = str(UUID(str(sample.get("sample_uuid", ""))))
    except ValueError:
        return unavailable("invalid_sample_uuid")
    if sample.get("unit") != "count":
        return unavailable("unsupported_step_unit")
    count = sample.get("value")
    if isinstance(count, bool) or not isinstance(count, (int, float, Decimal)):
        return unavailable("invalid_step_count")
    try:
        count = float(count)
    except (ValueError, OverflowError):
        return unavailable("invalid_step_count")
    if not math.isfinite(count) or count < 0:
        return unavailable("invalid_step_count")
    start, end = _instant(sample.get("started_at")), _instant(sample.get("ended_at"))
    if start is None or end is None:
        return unavailable("timezone_aware_interval_required")
    duration = (end - start).total_seconds()
    if duration <= 0:
        return unavailable("positive_sample_duration_required")
    rate = count / duration * 60
    if not math.isfinite(rate):
        return unavailable("nonfinite_derived_rate")
    return {
        "status": "derived",
        "method": "step_count_divided_by_sample_elapsed_minutes",
        "interpretation": "sample_interval_mean_not_recorded_or_instantaneous_cadence",
        "value": rate,
        "unit": "steps/min",
        "source_sample_uuid": sample_uuid,
        "source_device": sample.get("source_device"),
        "started_at": start.isoformat(),
        "ended_at": end.isoformat(),
        "duration_seconds": duration,
        "step_count": count,
        "coverage": "this_source_sample_interval_only",
        "pause_adjustment": "none_elapsed_time_includes_any_pauses",
        "workout_average": None,
    }
