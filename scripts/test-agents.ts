import { createClient } from '@supabase/supabase-js'
import 'dotenv/config'

const supabaseUrl = process.env.SUPABASE_URL ?? 'https://ltbsxbvfsxtnharjvqcm.supabase.co'
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY
const tickSecret = process.env.TICK_SECRET
const engineUrl = process.env.ECONOMY_ENGINE_URL ?? 'http://localhost:3000'

if (!serviceRoleKey) {
  throw new Error('SUPABASE_SERVICE_ROLE_KEY is required')
}

if (!tickSecret) {
  throw new Error('TICK_SECRET is required')
}

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
})

async function main() {
  const response = await fetch(`${engineUrl}/tick/agents`, {
    method: 'POST',
    headers: {
      'x-tick-secret': tickSecret,
    },
  })

  const result = await response.json()
  if (!response.ok || !result.success) {
    throw new Error(`agent tick failed: ${response.status} ${JSON.stringify(result)}`)
  }

  console.log(`ok - agent tick processed ${result.agentsProcessed} agents with ${result.actions} actions`)

  const tickId = result.tickId as string
  const { data: actionRows, error: actionError } = await supabase
    .from('agent_action_log')
    .select('id, agent_id, action, tick_id')
    .eq('tick_id', tickId)
    .limit(10)

  if (actionError) {
    throw new Error(`agent action log query failed: ${actionError.message}`)
  }

  if ((actionRows?.length ?? 0) !== result.actions) {
    throw new Error(`expected ${result.actions} action rows for tick ${tickId}, got ${actionRows?.length ?? 0}`)
  }

  console.log('ok - agent action log rows match tick result')

  const { data: agents, error: agentError } = await supabase
    .from('agents')
    .select('id, name, district_id, role')
    .eq('active', true)
    .limit(1)

  if (agentError) {
    throw new Error(`agent query failed: ${agentError.message}`)
  }

  if (!agents?.length) {
    throw new Error('no active agents found')
  }

  const { data: balances, error: balanceError } = await supabase
    .from('agent_wallet_balances')
    .select('agent_id, cash_clean, cash_dirty')
    .eq('agent_id', agents[0].id)
    .single()

  if (balanceError) {
    throw new Error(`agent balance query failed: ${balanceError.message}`)
  }

  console.log(`ok - sample agent wallet read: ${balances.agent_id}`)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
