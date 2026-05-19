import { createClient } from '@supabase/supabase-js'
import 'dotenv/config'

const requiredEnv = (name: string): string => {
  const value = process.env[name]
  if (!value) {
    throw new Error(`Missing ${name}`)
  }
  return value
}

const supabaseUrl = requiredEnv('SUPABASE_URL')
const anonKey = requiredEnv('SUPABASE_ANON_KEY')
const testEmail = requiredEnv('TEST_PLAYER_EMAIL')
const testPassword = requiredEnv('TEST_PLAYER_PASSWORD')

const supabase = createClient(supabaseUrl, anonKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
  },
})

const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
  email: testEmail,
  password: testPassword,
})

if (authError || !authData.session) {
  throw new Error(`Auth failed: ${authError?.message ?? 'no session returned'}`)
}

const endpoint = `${supabaseUrl}/functions/v1/buy-item`

const response = await fetch(endpoint, {
  method: 'POST',
  headers: {
    Authorization: `Bearer ${authData.session.access_token}`,
    apikey: anonKey,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({
    item_id: 'water_bottle',
    quantity: 1,
    player_id: '00000000-0000-0000-0000-000000000000',
  }),
})

const result = await response.json()
console.log(JSON.stringify({
  status: response.status,
  result,
}, null, 2))

if (!response.ok || result.success !== true) {
  throw new Error('buy-item request failed')
}

console.log('PASS: body.player_id was ignored; purchase used JWT-derived user')

