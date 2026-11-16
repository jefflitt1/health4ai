"""Separately opted-in exact route snapshots; no timestamp-inferred association."""
import base64
import json
import os

import psycopg2.extras
from health4ai.workout_details import canonical_uuid


def get_workout_routes(workout_uuid: str, cursor: str | None = None, limit: int = 200) -> dict:
    """Read an observed route snapshot; invalid point counts remain explicit.

    Requires HEALTH4AI_WORKOUT_ROUTES_ENABLED=true independently of quantity
    detail opt-in. Returns coordinates only from the configured user's current
    completed export. This is not an automatic-live-route or precision guarantee.
    """
    if os.environ.get('HEALTH4AI_WORKOUT_ROUTES_ENABLED') != 'true':
        return {'status': 'feature_disabled'}
    from health4ai import tools
    workout = canonical_uuid(workout_uuid)
    user = tools.validate_user_id(tools.current_user_id.get())
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 500:
        raise ValueError('limit must be an integer from 1 to 500')
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
        more = len(rows) > limit
        rows = rows[:limit]
        for row in rows:
            row['timestamp'] = row['timestamp'].isoformat()
        token = None
        if more:
            token = base64.urlsafe_b64encode(json.dumps({'user': user, 'workout': workout,
                'export': export['export_uuid'], 'route': rows[-1]['route_uuid'],
                'index': rows[-1]['point_index']}).encode()).decode()
        return {'status': 'complete_snapshot', 'workout_uuid': workout, **dict(export),
                'coverage': 'observed_only', 'points': rows, 'next_cursor': token}
    finally:
        conn.close()
