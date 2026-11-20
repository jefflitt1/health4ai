"""Separately opted-in exact route snapshots; no timestamp-inferred association."""
import base64
import json
import os

import psycopg2.extras
from health4ai.workout_details import canonical_uuid
from health4ai.workout_splits import UNITS, compute_splits

MAX_SPLIT_POINTS = 100000


def get_workout_routes(workout_uuid: str, cursor: str | None = None, limit: int = 200,
                       splits: str | None = None) -> dict:
    """Read an observed route snapshot; invalid point counts remain explicit.

    Requires HEALTH4AI_WORKOUT_ROUTES_ENABLED=true independently of quantity
    detail opt-in. Returns coordinates only from the configured user's current
    completed export. This is not an automatic-live-route or precision guarantee.

    splits='km' or 'mi' adds per-unit splits computed over the WHOLE route snapshot
    (not just this page): distance, elapsed seconds, pace, elevation gain/loss when
    altitude was recorded, final partial split flagged. Derived from GPS route points
    only; a workout with no exported route has no splits, and distance samples are not
    used. Recorded pauses are excluded only when the workout's event export is complete;
    otherwise time_basis says elapsed_including_pauses. First page only (no cursor).
    """
    if os.environ.get('HEALTH4AI_WORKOUT_ROUTES_ENABLED') != 'true':
        return {'status': 'feature_disabled'}
    from health4ai import tools
    workout = canonical_uuid(workout_uuid)
    user = tools.validate_user_id(tools.current_user_id.get())
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 500:
        raise ValueError('limit must be an integer from 1 to 500')
    if splits is not None:
        if splits not in UNITS:
            raise ValueError("splits must be 'km' or 'mi'")
        if cursor is not None:
            raise ValueError('splits cover the whole route; request them without a cursor')
    position = None
    if cursor is not None:
        try:
            if not isinstance(cursor, str) or len(cursor) > 1024:
                raise ValueError()
            position = json.loads(base64.b64decode(cursor, altchars=b'-_', validate=True))
            if not isinstance(position, dict) or set(position) != {'user', 'workout', 'export', 'route', 'index'}:
                raise ValueError()
            for key in ('user', 'workout', 'export', 'route'):
                position[key] = canonical_uuid(position[key])
            index = position['index']
            if isinstance(index, bool) or not isinstance(index, int) or not 0 <= index < 100000:
                raise ValueError()
            if position['user'] != user or position['workout'] != workout:
                raise ValueError()
        except (ValueError, TypeError, UnicodeError):
            raise ValueError('Invalid workout route cursor') from None
    conn = tools._connect()
    try:
        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
                cur.execute("SET LOCAL statement_timeout='15s'")
                cur.execute('''SELECT export_uuid::text, routes, invalid_counts
                    FROM public.healthkit_workout_route_exports
                    WHERE user_id=%s AND workout_uuid=%s AND is_current AND completed_at IS NOT NULL''',
                            (user, workout))
                export = cur.fetchone()
                if not export:
                    return {'status': 'snapshot_unavailable', 'coverage': 'unknown'}
                if position and position['export'] != export['export_uuid']:
                    return {'status': 'snapshot_replaced', 'restart_required': True}
                cur.execute('''SELECT route_uuid::text, point_index, timestamp, latitude, longitude,
                    altitude, horizontal_accuracy, vertical_accuracy FROM public.healthkit_workout_route_points
                    WHERE user_id=%s AND workout_uuid=%s AND export_uuid=%s
                    AND (%s::uuid IS NULL OR (route_uuid,point_index)>(%s::uuid,%s::integer))
                    ORDER BY route_uuid,point_index LIMIT %s''',
                            (user, workout, export['export_uuid'], position['route'] if position else None,
                             position['route'] if position else None, position['index'] if position else None, limit + 1))
                rows = [dict(row) for row in cur.fetchall()]
                split_result = None
                if splits is not None:
                    split_result = _route_splits(cur, user, workout, export['export_uuid'], splits)
        more = len(rows) > limit
        rows = rows[:limit]
        for row in rows:
            row['timestamp'] = row['timestamp'].isoformat()
        token = None
        if more:
            token = base64.urlsafe_b64encode(json.dumps({'user': user, 'workout': workout,
                'export': export['export_uuid'], 'route': rows[-1]['route_uuid'],
                'index': rows[-1]['point_index']}).encode()).decode()
        result = {'status': 'complete_snapshot', 'workout_uuid': workout, **dict(export),
                  'coverage': 'observed_only', 'points': rows, 'next_cursor': token}
        if split_result is not None:
            result['splits'] = split_result
        return result
    finally:
        conn.close()


def _route_splits(cur, user, workout, export_uuid, unit):
    """Splits over every point of the current export plus the workout's recorded events."""
    cur.execute('''SELECT route_uuid::text, point_index, timestamp, latitude, longitude,
        altitude, horizontal_accuracy, vertical_accuracy FROM public.healthkit_workout_route_points
        WHERE user_id=%s AND workout_uuid=%s AND export_uuid=%s
        ORDER BY route_uuid,point_index LIMIT %s''', (user, workout, export_uuid, MAX_SPLIT_POINTS + 1))
    points = [dict(row) for row in cur.fetchall()]
    if len(points) > MAX_SPLIT_POINTS:
        return {'status': 'too_many_points', 'limit': MAX_SPLIT_POINTS}
    cur.execute('''SELECT metadata FROM public.healthkit_metrics
        WHERE user_id=%s AND metric_type='HKWorkoutTypeIdentifier'
        AND lower(metadata->>'workout_uuid')=%s
        ORDER BY started_at DESC LIMIT 1''', (user, workout))
    row = cur.fetchone()
    meta = (row or {}).get('metadata') or {}
    return compute_splits(points, unit, meta.get('workout_events'), meta.get('workout_events_truncated'))
