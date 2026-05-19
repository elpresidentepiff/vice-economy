import { createClient } from '@supabase/supabase-js'
import 'dotenv/config'

const supabaseUrl = process.env.SUPABASE_URL ?? 'https://ltbsxbvfsxtnharjvqcm.supabase.co'
const publishableKey = process.env.SUPABASE_ANON_KEY ?? process.env.SUPABASE_PUBLISHABLE_KEY
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY
const testEmail = process.env.TEST_PLAYER_EMAIL
const testPassword = process.env.TEST_PLAYER_PASSWORD
const runMutatingTests = process.env.RUN_MUTATING_CRYPTO_TESTS === 'true'
const seedCash = process.env.CRYPTO_TEST_SEED_CASH === 'true'

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

async function readRates() {
  const { data, error } = await supabase
    .from('crypto_exchange_rates')
    .select('from_currency, to_currency, rate, spread_bps')
    .eq('active', true)
    .order('from_currency', { ascending: true })
    .order('to_currency', { ascending: true })

  if (error) {
    throw new Error(`crypto rate read failed: ${error.message}`)
  }

  if (!data?.length) {
    throw new Error('expected active crypto exchange rates')
  }

  console.log(`ok - read ${data.length} active simulated crypto rates`)
  return data
}

async function maybeSeedCleanCash(playerId: string) {
  if (!seedCash) {
    return
  }

  if (!admin) {
    throw new Error('CRYPTO_TEST_SEED_CASH=true requires SUPABASE_SERVICE_ROLE_KEY')
  }

  const { data: tx, error: txError } = await admin
    .from('transactions')
    .insert({
      player_id: playerId,
      transaction_type: 'grant',
      total_amount: 5000,
      currency: 'cash_clean',
      metadata: {
        source: 'test-crypto',
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
      reason: 'crypto_test_seed_grant',
      reference_type: 'transaction',
      reference_id: tx.id,
      metadata: {
        source: 'test-crypto',
      },
    })

  if (ledgerError) {
    throw new Error(`cash seed ledger insert failed: ${ledgerError.message}`)
  }

  console.log('ok - seeded clean cash for crypto exchange test')
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

async function callExchange(accessToken: string, body: Record<string, unknown>) {
  const response = await fetch(`${supabaseUrl}/functions/v1/exchange-crypto`, {
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

async function runExchangeTests() {
  if (!testEmail || !testPassword) {
    throw new Error('TEST_PLAYER_EMAIL and TEST_PLAYER_PASSWORD are required when RUN_MUTATING_CRYPTO_TESTS=true')
  }

  const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
    email: testEmail,
    password: testPassword,
  })

  if (authError || !authData.user || !authData.session) {
    throw new Error(`auth failed: ${authError?.message ?? 'missing session'}`)
  }

  await maybeSeedCleanCash(authData.user.id)

  const walletBefore = await readWallet(authData.user.id)
  const beforeCash = Number(walletBefore.cash_clean)
  const beforeUsdt = Number(walletBefore.sim_usdt)

  const { response, result } = await callExchange(authData.session.access_token, {
    from_currency: 'cash_clean',
    to_currency: 'sim_usdt',
    amount: 1000,
  })

  if (!response.ok || result.success !== true) {
    throw new Error(`exchange failed: ${response.status} ${JSON.stringify(result)}`)
  }

  if (result.amount_received <= 0 || result.spread_amount < 0) {
    throw new Error(`unexpected exchange result: ${JSON.stringify(result)}`)
  }

  const walletAfter = await readWallet(authData.user.id)
  if (Number(walletAfter.cash_clean) !== beforeCash - 1000) {
    throw new Error('cash_clean did not decrease by exchanged amount')
  }

  if (Number(walletAfter.sim_usdt) !== beforeUsdt + Number(result.amount_received)) {
    throw new Error('sim_usdt did not increase by received amount')
  }

  console.log(`ok - exchanged 1000 cash_clean for ${result.amount_received} sim_usdt`)

  const insufficient = await callExchange(authData.session.access_token, {
    from_currency: 'cash_clean',
    to_currency: 'sim_usdt',
    amount: 999999999999,
  })

  if (insufficient.response.ok || insufficient.result.success === true) {
    throw new Error('insufficient balance exchange unexpectedly succeeded')
  }

  console.log('ok - insufficient balance exchange failed')
}

async function main() {
  await readRates()

  if (!runMutatingTests) {
    console.log('skip - set RUN_MUTATING_CRYPTO_TESTS=true with test player credentials to run exchange mutation checks')
    return
  }

  await runExchangeTests()
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
