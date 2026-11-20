"""Per-km / per-mile splits derived from an exported GPS route (#54).

Distance is the haversine sum over consecutive route points of one route; it is never
bridged across separate routes and never estimated from distance samples, so a workout
without an exported route has no splits. A boundary crossing inside a segment is placed
by linear interpolation of distance and of moving time along that segment.

Time basis: recorded pause/resume (and motion pause/resume) events are excluded only when
the workout's event export is present and not truncated. Otherwise every second between
points counts and the result says `elapsed_including_pauses`.
"""
import math
from datetime import datetime

EARTH_RADIUS_M = 6371008.8
UNITS = {"km": 1000.0, "mi": 1609.344}
MAX_HORIZONTAL_ACCURACY_M = 50.0
_PAUSE = {"pause": "resume", "motion_paused": "motion_resumed"}


def _haversine(a, b):
    lat1, lat2 = math.radians(a["latitude"]), math.radians(b["latitude"])
    dlat = lat2 - lat1
    dlon = math.radians(b["longitude"] - a["longitude"])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(h)))


def _ts(value):
    if isinstance(value, datetime):
        return value.timestamp()
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()


def _paused_intervals(events, end):
    """[start, end) seconds for each recorded pause; an unmatched pause runs to `end`."""
    intervals = []
    open_kind = {}
    for ev in sorted((e for e in events if e.get("started_at")), key=lambda e: _ts(e["started_at"])):
        kind = ev.get("type")
        at = _ts(ev["started_at"])
        if kind in _PAUSE and kind not in open_kind:
            open_kind[kind] = at
        else:
            for pause_kind, resume_kind in _PAUSE.items():
                if kind == resume_kind and pause_kind in open_kind:
                    intervals.append((open_kind.pop(pause_kind), at))
    intervals.extend((start, end) for start in open_kind.values())
    # A manual pause and a motion pause can overlap; summing both would subtract the shared
    # time twice, so overlapping intervals are merged first.
    merged = []
    for start, stop in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], stop))
        else:
            merged.append((start, stop))
    return merged


def _route_segments(usable):
    """Consecutive point pairs within each route, in time order, never across routes.

    Sorting every point by time interleaves routes recorded at the same moment (two devices)
    and the same-route check then drops every segment. Each route is walked on its own, and
    a route that starts before the previous accepted route ends is a duplicate recording of
    the same movement and is left out, so distance is counted once. The time between two
    routes has no route and is neither distance nor moving time.
    """
    by_route = {}
    for p in usable:
        by_route.setdefault(str(p["route_uuid"]), []).append(p)
    routes = sorted(by_route.values(), key=lambda pts: (_ts(pts[0]["timestamp"]), str(pts[0]["route_uuid"])))
    segments, last_end, duplicates = [], None, 0
    for pts in routes:
        start, stop = _ts(pts[0]["timestamp"]), _ts(pts[-1]["timestamp"])
        if last_end is not None and start < last_end:
            duplicates += 1
            continue
        segments.extend(zip(pts, pts[1:]))
        last_end = stop
    return segments, duplicates


def _overlap(t0, t1, intervals):
    return sum(max(0.0, min(t1, e) - max(t0, s)) for s, e in intervals)


def compute_splits(points, unit, events, events_truncated):
    """Split a route snapshot into whole `unit` intervals plus a final partial one."""
    if unit not in UNITS:
        raise ValueError("splits must be 'km' or 'mi'")
    size = UNITS[unit]
    usable = [p for p in points if p["horizontal_accuracy"] <= MAX_HORIZONTAL_ACCURACY_M]
    skipped = len(points) - len(usable)
    usable.sort(key=lambda p: (_ts(p["timestamp"]), str(p["route_uuid"]), p["point_index"]))

    events_known = events is not None and events_truncated is False
    end = _ts(usable[-1]["timestamp"]) if usable else 0.0
    paused = _paused_intervals(events, end) if events_known else []

    splits = []
    current = {"distance": 0.0, "active": 0.0, "gain": 0.0, "loss": 0.0, "has_alt": False}

    def close(partial):
        dist = current["distance"]
        splits.append({
            "index": len(splits) + 1,
            "distance_m": round(dist, 1),
            "elapsed_seconds": round(current["active"], 1),
            "pace_seconds_per_unit": round(current["active"] / dist * size, 1) if dist > 0 else None,
            "elevation_gain_m": round(current["gain"], 1) if current["has_alt"] else None,
            "elevation_loss_m": round(current["loss"], 1) if current["has_alt"] else None,
            "partial": partial,
        })
        current.update(distance=0.0, active=0.0, gain=0.0, loss=0.0, has_alt=False)

    total = 0.0
    segments, overlapping_routes = _route_segments(usable)
    for prev, nxt in segments:
        t0, t1 = _ts(prev["timestamp"]), _ts(nxt["timestamp"])
        active = max(0.0, (t1 - t0) - _overlap(t0, t1, paused))
        dist = _haversine(prev, nxt) if active > 0 else 0.0
        climb = None
        if prev.get("altitude") is not None and nxt.get("altitude") is not None \
                and prev.get("vertical_accuracy", -1) >= 0 and nxt.get("vertical_accuracy", -1) >= 0:
            climb = nxt["altitude"] - prev["altitude"]
        total += dist
        done = 0.0  # fraction of this segment already assigned to closed splits
        while dist > 0 and current["distance"] + dist * (1 - done) >= size - 1e-9:
            frac = (size - current["distance"]) / dist
            _add(current, frac, dist, active, climb)
            done += frac
            close(partial=False)
        _add(current, 1 - done, dist, active, climb)
    if current["distance"] > 0.5:
        close(partial=True)

    return {
        "unit": unit,
        "split_distance_m": size,
        "time_basis": "moving_excluding_recorded_pauses" if events_known else "elapsed_including_pauses",
        "total_distance_m": round(total, 1),
        "points_used": len(usable),
        "points_skipped_low_accuracy": skipped,
        "overlapping_routes_skipped": overlapping_routes,
        "splits": splits,
        "notes": ("Derived from exported GPS route points only (haversine, accuracy <= 50 m); "
                  "no route means no splits. Heart rate is not included."),
    }


def _add(current, frac, dist, active, climb):
    if frac <= 0:
        return
    current["distance"] += dist * frac
    current["active"] += active * frac
    if climb is not None:
        current["has_alt"] = True
        if climb > 0:
            current["gain"] += climb * frac
        else:
            current["loss"] -= climb * frac
