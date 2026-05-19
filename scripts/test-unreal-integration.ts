import { createClient } from '@supabase/supabase-js'
import 'dotenv/config'

const supabaseUrl = process.env.SUPABASE_URL ?? 'https://ltbsxbvfsxtnharjvqcm.supabase.co'
const anonKey = process.env.SUPABASE_ANON_KEY ?? process.env.SUPABASE_PUBLISHABLE_KEY
const testEmail = process.env.TEST_PLAYER_EMAIL
const testPassword = process.env.TEST_PLAYER_PASSWORD
const runMutatingTests = process.env.RUN_MUTATING_UNREAL_TESTS === 'true'

if (!anonKey) {
  throw new Error('SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEY is required')
}

const supabase = createClient(supabaseUrl, anonKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
})

async function expectOk(name: string, error: unknown, count?: number) {
  if (error) {
    throw new Error(`${name} failed: ${JSON.stringify(error)}`)
  }

  if (typeof count === 'number' && count < 1) {
    throw new Error(`${name} returned no rows`)
  }

  console.log(`ok - ${name}`)
}

async function main() {
  const { data: districts, error: districtsError } = await supabase
    .from('districts')
    .select('district_id, name')
    .limit(10)
  await expectOk('public districts read', districtsError, districts?.length)

  const districtId = districts?.[0]?.district_id ?? 'vice_beach'
  const { data: districtPrices, error: districtPricesError } = await supabase
    .from('district_prices')
    .select('district_id, item_id, current_price')
    .eq('district_id', districtId)
    .limit(10)
  await expectOk('public district prices read', districtPricesError, districtPrices?.length)

  const { data: cohorts, error: cohortsError } = await supabase
    .from('npc_cohorts')
    .select('district_id, cohort_type, population')
    .limit(10)
  await expectOk('public NPC cohorts read', cohortsError, cohorts?.length)

  if (!testEmail || !testPassword) {
    console.log('skip - authenticated market/wallet/inventory checks need TEST_PLAYER_EMAIL and TEST_PLAYER_PASSWORD')
    return
  }

  const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
    email: testEmail,
    password: testPassword,
  })
  await expectOk('test player sign in', authError)

  const accessToken = authData.session?.access_token
  if (!accessToken) {
    throw new Error('test player sign in did not return an access token')
  }

  const { data: marketItems, error: marketError } = await supabase
    .from('market_items')
    .select('item_id, display_name, category, current_price')
    .eq('active', true)
    .limit(10)
  await expectOk('authenticated market items read', marketError, marketItems?.length)

  const { data: walletRows, error: walletError } = await supabase
    .from('wallet_balances')
    .select('cash_clean, cash_dirty')
    .limit(1)
  await expectOk('authenticated wallet read', walletError, walletRows?.length)

  const { error: inventoryError } = await supabase
    .from('player_inventory')
    .select('item_id, quantity')
    .limit(10)
  await expectOk('authenticated inventory read', inventoryError)

  if (!runMutatingTests) {
    console.log('skip - buy-item check needs RUN_MUTATING_UNREAL_TESTS=true')
    return
  }

  const response = await fetch(`${supabaseUrl}/functions/v1/buy-item`, {
    method: 'POST',
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      item_id: 'water_bottle',
      quantity: 1,
    }),
  })

  const body = await response.text()
  if (!response.ok) {
    throw new Error(`buy-item failed: ${response.status} ${body}`)
  }

  console.log('ok - buy-item edge function accepted test purchase')
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
