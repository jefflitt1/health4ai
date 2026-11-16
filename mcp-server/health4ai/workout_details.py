"""Opt-in, exact HealthKit association snapshots; never infer links from time overlap."""
import base64
import json
import os
import uuid

import psycopg2.extras
from health4ai.workout_cadence import derive_step_cadence


def canonical_uuid(value):
    if not isinstance(value, str):
        raise ValueError('Expected UUID string')
    return str(uuid.UUID(value))


def get_workout_details(workout_uuid: str, cursor: str | None = None, limit: int = 200) -> dict:
    """Page exact associated quantity samples from an immutable observed snapshot.

    Requires HEALTH4AI_WORKOUT_DETAILS_ENABLED=true and the optional schema.
    Coverage is observed_only, including empty snapshots; it does not establish
    HealthKit read permission or the absence of undisclosed data. No routes/FIT.
    """
    if os.environ.get('HEALTH4AI_WORKOUT_DETAILS_ENABLED') != 'true':
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
            if not isinstance(position, dict) or set(position) != {'user', 'workout', 'export', 'after'}:
                raise ValueError()
            position = {k: canonical_uuid(v) for k, v in position.items()}
            if position['user'] != user or position['workout'] != workout:
                raise ValueError()
        except (ValueError, TypeError, UnicodeError):
            raise ValueError('Invalid workout detail cursor') from None
    conn = tools._connect()
    try:
        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
                cur.execute("SET LOCAL statement_timeout='15s'")
                cur.execute('''SELECT export_uuid::text, query_types, observed_count
                    FROM public.healthkit_workout_exports
                    WHERE user_id=%s AND workout_uuid=%s AND is_current AND completed_at IS NOT NULL''',
                            (user, workout))
                export = cur.fetchone()
                if not export:
                    return {'status': 'snapshot_unavailable', 'coverage': 'unknown'}
                if position and position['export'] != export['export_uuid']:
                    return {'status': 'snapshot_replaced', 'restart_required': True}
                cur.execute('''SELECT sample_uuid::text, metric_type, value, unit, source_device,
                    started_at, ended_at FROM public.healthkit_workout_samples
                    WHERE user_id=%s AND workout_uuid=%s AND export_uuid=%s
                    AND (%s::uuid IS NULL OR sample_uuid>%s::uuid)
                    ORDER BY sample_uuid LIMIT %s''',
                            (user, workout, export['export_uuid'],
                             position['after'] if position else None,
                             position['after'] if position else None, limit + 1))
                rows = [dict(row) for row in cur.fetchall()]
        more = len(rows) > limit
        rows = rows[:limit]
        for row in rows:
            for key in ('started_at', 'ended_at'):
                row[key] = row[key].isoformat()
            if row['metric_type'] == 'HKQuantityTypeIdentifierStepCount':
                row['derived_cadence'] = derive_step_cadence(row, exact_workout_association=True)
        token = None
        if more:
            token = base64.urlsafe_b64encode(json.dumps({'user': user, 'workout': workout,
                'export': export['export_uuid'], 'after': rows[-1]['sample_uuid']}).encode()).decode()
        return {'status': 'complete_snapshot', 'workout_uuid': workout, **dict(export),
                'coverage': 'observed_only', 'samples': rows, 'next_cursor': token}
    finally:
        conn.close()
