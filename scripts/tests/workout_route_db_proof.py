"""Invoked by the quantity proof on the same disposable local database."""
from pathlib import Path
import os
import uuid
from psycopg2.extras import Json


def exercise_routes(sql, check, denied, user, other, workout):
    root = Path(__file__).resolve().parents[2]
    sql('RESET ROLE')
    sql((root / 'supabase/optional/workout-routes-v1.sql').read_text())
    for role in ('anon', 'authenticated'):
        sql('SET ROLE ' + role)
        denied(lambda: sql('SELECT * FROM public.healthkit_workout_route_points'), role + ' cannot read location')
        denied(lambda: sql("SELECT public.health4ai_workout_routes_v1(%s,'capabilities',NULL,NULL,'{}')", (user,)),
               role + ' cannot invoke route writer')
    sql('SET ROLE service_role')
    def rpc(op, export=None, payload=None, uid=user):
        return sql('SELECT public.health4ai_workout_routes_v1(%s,%s,%s,%s,%s)',
                   (uid, op, workout, export, Json(payload or {})))[0][0]
    route = str(uuid.uuid4())
    point = {'route_uuid': route, 'point_index': 0, 'timestamp': '2026-11-16T10:00:00Z',
             'latitude': 0.0, 'longitude': 0.0, 'altitude': None,
             'horizontal_accuracy': 5.0, 'vertical_accuracy': -1.0}
    routes = [{'route_uuid': route, 'source_count': 3}]
    revision = str(uuid.uuid4())
    check(rpc('capabilities')['capabilities'] == ['workout_routes_v1'], 'separate route capability')
    rpc('begin', revision, {'routes': routes})
    check(rpc('page', revision, {'points': [point]})['observed_count'] == 1, 'route first point stored')
    check(rpc('page', revision, {'points': [point]})['observed_count'] == 1, 'route retry idempotent')
    denied(lambda: rpc('page', revision, {'points': [dict(point, latitude=10)]}), 'conflicting route retry rejected')
    for change in ({'latitude': 91}, {'longitude': 181}, {'altitude': 1}, {'horizontal_accuracy': -1},
                   {'point_index': 3}, {'route_uuid': str(uuid.uuid4())}):
        denied(lambda: rpc('page', revision, {'points': [dict(point, point_index=1, **change)]})
               if 'point_index' not in change else rpc('page', revision, {'points': [dict(point, **change)]}),
               'reject invalid route point ' + next(iter(change)))
    rpc('page', revision, {'points': [dict(point, point_index=2, vertical_accuracy=3, altitude=7)]})
    denied(lambda: rpc('finalize', revision, {'invalid_counts': [{'route_uuid': route, 'invalid_count': 0}]}),
           'route incomplete count cannot finalize')
    check(sql('SELECT count(*) FROM public.healthkit_workout_route_exports WHERE is_current')[0][0] == 0,
          'partial route snapshot invisible')
    counts = [{'route_uuid': route, 'invalid_count': 1}]
    check(rpc('finalize', revision, {'invalid_counts': counts})['invalid_counts'] == counts,
          'explicit invalid count preserved')
    rpc('finalize', revision, {'invalid_counts': counts})
    denied(lambda: rpc('page', revision, {'points': [point]}), 'completed route immutable')
    other_revision = str(uuid.uuid4())
    rpc('begin', other_revision, {'routes': []}, other)
    rpc('finalize', other_revision, {'invalid_counts': []}, other)
    denied(lambda: rpc('page', revision, {'points': [point]}, other), 'cross-tenant route revision refused')
    os.environ['HEALTH4AI_WORKOUT_ROUTES_ENABLED'] = 'true'
    from health4ai.workout_routes import get_workout_routes
    from health4ai import tools
    tools.current_user_id.set(user)
    first = get_workout_routes(workout, limit=1)
    check(first['points'][0]['altitude'] is None and first['invalid_counts'] == counts,
          'MCP preserves unknown altitude and visible invalid count')
    # The core ingest table always exists in a real deployment; this disposable database
    # loads only the optional schema, so a minimal core shape stands in for it. The UUID is
    # stored upper-case, as iOS writes uuidString, to prove the case-insensitive match.
    sql('RESET ROLE')
    sql('''CREATE TABLE IF NOT EXISTS public.healthkit_metrics(user_id uuid, metric_type text,
        started_at timestamptz, metadata jsonb)''')
    sql("INSERT INTO public.healthkit_metrics VALUES(%s,'HKWorkoutTypeIdentifier','2026-11-16T10:00:00Z',%s)",
        (user, Json({'workout_uuid': workout.upper(), 'workout_events': [],
                     'workout_events_truncated': False})))
    sql('SET ROLE service_role')
    with_splits = get_workout_routes(workout, limit=1, splits='km')
    check(with_splits['points'] == first['points'] and with_splits['splits']['unit'] == 'km'
          and with_splits['splits']['points_used'] >= 2
          and with_splits['splits']['time_basis'] == 'moving_excluding_recorded_pauses',
          'route splits read the whole snapshot and the upper-case workout event row on real PostgreSQL')
    second = get_workout_routes(workout, cursor=first['next_cursor'], limit=1)
    check(second['points'][0]['point_index'] == 2 and second['next_cursor'] is None,
          'route cursor traverses original source index gaps')
    tools.current_user_id.set(other)
    try:
        get_workout_routes(workout, cursor=first['next_cursor'])
    except ValueError:
        check(True, 'route cursor tenant-bound')
    else:
        raise AssertionError('cross-tenant route cursor accepted')
    tools.current_user_id.set(user)
    older, newer = str(uuid.uuid4()), str(uuid.uuid4())
    for item in (older, newer):
        rpc('begin', item, {'routes': []})
    rpc('finalize', newer, {'invalid_counts': []})
    denied(lambda: rpc('finalize', older, {'invalid_counts': []}), 'late older route revision refused')
    check(get_workout_routes(workout, cursor=first['next_cursor'])['status'] == 'snapshot_replaced',
          'route cursor invalidated by newer snapshot')
    rpc('delete_all')
    check(sql('SELECT count(*) FROM public.healthkit_workout_route_points WHERE user_id=%s', (user,))[0][0] == 0,
          'route erase cascades coordinates')
    check(sql('SELECT count(*) FROM public.healthkit_workout_route_exports WHERE user_id=%s', (other,))[0][0] == 1,
          'route erase preserves other tenant')
    check(get_workout_routes(workout)['status'] == 'snapshot_unavailable', 'deleted route not exposed by MCP')
    os.environ['HEALTH4AI_WORKOUT_ROUTES_ENABLED'] = 'false'
    check(get_workout_routes('invalid')['status'] == 'feature_disabled', 'route flag independent/default off')
