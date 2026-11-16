import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.119.0'
import { handler } from './handler.ts'

const url = Deno.env.get('SUPABASE_URL')!
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const admin = createClient(url, key)
Deno.serve(handler({
  enabled: Deno.env.get('HEALTH4AI_WORKOUT_DETAILS_ENABLED') === 'true',
  authenticate: async token => {
    const { data, error } = await admin.auth.getUser(token)
    return error ? null : data.user?.id ?? null
  },
  rpc: async args => await admin.rpc('health4ai_workout_details_v1', args),
}))
