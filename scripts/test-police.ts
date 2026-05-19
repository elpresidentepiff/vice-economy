import { createClient } from '@supabase/supabase-js'
import 'dotenv/config'

const supabaseUrl = process.env.SUPABASE_URL ?? 'https://ltbsxbvfsxtnharjvqcm.supabase.co'
const publishableKey = process.env.SUPABASE_ANON_KEY ?? process.env.SUPABASE_PUBLISHABLE_KEY
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY
const testEmail = process.env.TEST_PLAYER_EMAIL
const testPassword = process.env.TEST_PLAYER_PASSWORD
const runMutatingTests = process.env.RUN_MUTATING_POLICE_TESTS === 'true'
const seedCash = process.env.POLICE_TEST_SEED_CASH === 'true'
const districtId = process.env.POLICE_TEST_DISTRICT_ID ?? 'port'
const engineUrl = process.env.ECONOMY_ENGINE_URL
const tickSecret = process.env.TICK_SECRET

if (!publishableKey) {
  throw new Error('SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEY is required')
}

const supabase = createClient(supabaseUrl, publishableKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
})

const admin = serviceRoleKey
  ? createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    })
  : null

async function readPoliceDistricts() {
  const { data, error } = await supabase
    .from('districts')
    .select('district_id, police_presence, checkpoint_level, supply_disruption')
    .order('district_id', { ascending: true })

  if (error) {
    throw new Error(`police district read failed: ${error.message}`)
  }

  if (!data?.length) {
    throw new Error('expected districts with police fields')
  }

  console.log(`ok - read ${data.length} districts with police state`)
  return data
}

async function maybeRunPoliceTick() {
  if (!engineUrl || !tickSecret) {
    console.log('skip - set ECONOMY_ENGINE_URL and TICK_SECRET to run /tick/police')
    return
  }

  const response = await fetch(`${engineUrl}/tick/police`, {
    method: 'POST',
    headers: {
      'x-tick-secret': tickSecret,
    },
  })

  const result = await response.json()
  if (!response.ok || result.success !== true) {
    throw new Error(`/tick/police failed: ${response.status} ${JSON.stringify(result)}`)
  }

  console.log(`ok - /tick/police updated ${result.updated} districts`)
}

async function maybeSeedCleanCash(playerId: string) {
  if (!seedCash) {
    return
  }

  if (!admin) {
    throw new Error('POLICE_TEST_SEED_CASH=true requires SUPABASE_SERVICE_ROLE_KEY')
  }

  const { data: tx, error: txError } = await admin
    .from('transactions')
    .insert({
      player_id: playerId,
      transaction_type: 'grant',
      total_amount: 5000,
      currency: 'cash_clean',
      metadata: {
        source: 'test-police',
      },
    })
    .select('id')
    .single()

  if (txError) {
    throw new Error(`cash seed transaction failed: ${txError.message}`)
  }

  const { error: ledgerError } = await admin
    .from('wallet_ledger')
    .insert({
      player_id: playerId,
      delta_amount: 5000,
      currency: 'cash_clean',
      reason: 'police_test_seed_grant',
      reference_type: 'transaction',
      reference_id: tx.id,
      metadata: {
        source: 'test-police',
      },
    })

  if (ledgerError) {
    throw new Error(`cash seed ledger insert failed: ${ledgerError.message}`)
  }

  console.log('ok - seeded clean cash for police bribe test')
}

async function seedPlayerHeat(playerId: string, heatLevel: number) {
  if (!admin) {
    throw new Error('mutating police tests require SUPABASE_SERVICE_ROLE_KEY')
  }

  const { error } = await admin
    .from('player_heat')
    .upsert({
      player_id: playerId,
      district_id: districtId,
      heat_level: heatLevel,
    }, {
      onConflict: 'player_id,district_id',
    })

  if (error) {
    throw new Error(`player heat seed failed: ${error.message}`)
  }

  console.log(`ok - seeded ${heatLevel} player heat in ${districtId}`)
}

async function readWallet(playerId: string) {
  const { data, error } = await supabase
    .from('wallet_balances')
    .select('player_id, cash_clean, cash_dirty, sim_usdt, sim_usdc')
    .eq('player_id', playerId)
    .single()

  if (error) {
    throw new Error(`wallet read failed: ${error.message}`)
  }

  return data
}

async function readHeat(playerId: string) {
  const { data, error } = await supabase
    .from('player_heat')
    .select('district_id, heat_level')
    .eq('player_id', playerId)
    .eq('district_id', districtId)
    .single()

  if (error) {
    throw new Error(`player heat read failed: ${error.message}`)
  }

  return data
}

async function callBribe(accessToken: string, body: Record<string, unknown>) {
  const response = await fetch(`${supabaseUrl}/functions/v1/bribe-police`, {
    method: 'POST',
    headers: {
      apikey: publishableKey,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  })

  const result = await response.json()
  return { response, result }
}

async function runBribeTests() {
  if (!testEmail || !testPassword) {
    throw new Error('TEST_PLAYER_EMAIL and TEST_PLAYER_PASSWORD are required when RUN_MUTATING_POLICE_TESTS=true')
  }

  const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
    email: testEmail,
    password: testPassword,
  })

  if (authError || !authData.user || !authData.session) {
    throw new Error(`auth failed: ${authError?.message ?? 'missing session'}`)
  }

  await maybeSeedCleanCash(authData.user.id)
  await seedPlayerHeat(authData.user.id, 20)

  const walletBefore = await readWallet(authData.user.id)
  const heatBefore = await readHeat(authData.user.id)

  const { response, result } = await callBribe(authData.session.access_token, {
    district_id: districtId,
    amount: 500,
    player_id: '00000000-0000-0000-0000-000000000000',
  })

  if (!response.ok || result.success !== true) {
    throw new Error(`bribe failed: ${response.status} ${JSON.stringify(result)}`)
  }

  const walletAfter = await readWallet(authData.user.id)
  const heatAfter = await readHeat(authData.user.id)

  if (Number(walletAfter.cash_clean) !== Number(walletBefore.cash_clean) - 500) {
    throw new Error('cash_clean did not decrease by bribe amount')
  }

  if (Number(heatAfter.heat_level) !== Number(heatBefore.heat_level) - 5) {
    throw new Error('player heat did not decrease by expected bribe scaling')
  }

  console.log(`ok - bribe reduced heat from ${heatBefore.heat_level} to ${heatAfter.heat_level}`)

  const { data: bribes, error: bribeError } = await supabase
    .from('bribe_events')
    .select('id, amount, heat_before, heat_after')
    .order('created_at', { ascending: false })
    .limit(1)

  if (bribeError || !bribes?.length) {
    throw new Error(`bribe event read failed: ${bribeError?.message ?? 'missing bribe event'}`)
  }

  console.log('ok - bribe event logged')

  const insufficient = await callBribe(authData.session.access_token, {
    district_id: districtId,
    amount: 999999999999,
  })

  if (insufficient.result.success === true) {
    throw new Error('insufficient cash bribe unexpectedly succeeded')
  }

  console.log('ok - insufficient clean cash bribe failed')
}

async function main() {
  await readPoliceDistricts()
  await maybeRunPoliceTick()

  if (!runMutatingTests) {
    console.log('skip - set RUN_MUTATING_POLICE_TESTS=true with test player credentials to run bribe mutation checks')
    return
  }

  await runBribeTests()
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
