import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.119.0'
import { handler } from '../workout-details/handler.ts'
import { validateRoutes } from './validation.ts'

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
Deno.serve(handler({
  enabled: Deno.env.get('HEALTH4AI_WORKOUT_ROUTES_ENABLED') === 'true',
  validatePayload: validateRoutes,
  authenticate: async token => {
    const { data, error } = await admin.auth.getUser(token)
    return error ? null : data.user?.id ?? null
  },
  rpc: async args => await admin.rpc('health4ai_workout_routes_v1', args),
}))
