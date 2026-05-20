import { createClient } from '@supabase/supabase-js'
import { randomUUID } from 'node:crypto'
import 'dotenv/config'

const supabaseUrl = process.env.SUPABASE_URL ?? 'https://ltbsxbvfsxtnharjvqcm.supabase.co'
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY
const engineUrl = process.env.ECONOMY_ENGINE_URL ?? 'http://localhost:3000'
const tickSecret = process.env.TICK_SECRET
const runMutatingTests = process.env.RUN_MUTATING_ARENA_TESTS === 'true'

if (!serviceRoleKey) {
  throw new Error('SUPABASE_SERVICE_ROLE_KEY is required')
}

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
})

type Agent = {
  id: string
  name: string
  generation: number
  ambition: number | string
  risk_tolerance: number | string
  role: string
}

async function callArenaTick(secret?: string) {
  const response = await fetch(`${engineUrl}/tick/arena`, {
    method: 'POST',
    headers: secret ? { 'x-tick-secret': secret } : {},
  })
  const result = await response.json().catch(() => ({}))
  return { response, result }
}

async function countActiveAgents() {
  const { count, error } = await supabase
    .from('agents')
    .select('id', { count: 'exact', head: true })
    .eq('active', true)
    .eq('status', 'active')

  if (error) {
    throw new Error(`active agent count failed: ${error.message}`)
  }

  return count ?? 0
}

async function readSampleAgent() {
  const { data, error } = await supabase
    .from('agents')
    .select('id, name, generation, ambition, risk_tolerance, role')
    .eq('active', true)
    .eq('status', 'active')
    .order('created_at', { ascending: true })
    .limit(1)
    .single()

  if (error || !data) {
    throw new Error(`sample agent query failed: ${error?.message ?? 'missing agent'}`)
  }

  return data as Agent
}

function assertTraitDelta(parentValue: number | string, childValue: number | string, label: string) {
  const delta = Math.abs(Number(parentValue) - Number(childValue))
  if (delta > 0.1001) {
    throw new Error(`${label} mutated by ${delta}, expected <= 0.1`)
  }
}

async function boostParent(agentId: string) {
  const { data, error } = await supabase.rpc('apply_agent_cash_delta', {
    p_agent_id: agentId,
    p_delta_amount: 60_000,
    p_currency: 'cash_clean',
    p_reason: 'arena_test_boost',
    p_tick_id: randomUUID(),
    p_details: {
      source: 'test-arena',
    },
  })

  if (error || data !== true) {
    throw new Error(`arena parent boost failed: ${error?.message ?? JSON.stringify(data)}`)
  }
}

async function verifyBirth(parent: Agent, activeBefore: number) {
  const { data: births, error } = await supabase
    .from('agent_evolution_log')
    .select('agent_id, parent_id, generation, traits_before, traits_after, details, tick_id, created_at')
    .eq('event_type', 'birth')
    .eq('parent_id', parent.id)
    .order('created_at', { ascending: false })
    .limit(1)

  if (error || !births?.length) {
    throw new Error(`birth log missing: ${error?.message ?? 'no birth rows'}`)
  }

  const birth = births[0]
  const { data: child, error: childError } = await supabase
    .from('agents')
    .select('id, parent_id, generation, ambition, risk_tolerance, role, active, status')
    .eq('id', birth.agent_id)
    .single()

  if (childError || !child) {
    throw new Error(`child lookup failed: ${childError?.message ?? 'missing child'}`)
  }

  if (child.parent_id !== parent.id) {
    throw new Error('child parent_id does not match boosted parent')
  }

  if (Number(child.generation) !== Number(parent.generation) + 1) {
    throw new Error('child generation did not increment')
  }

  assertTraitDelta(parent.ambition, child.ambition, 'ambition')
  assertTraitDelta(parent.risk_tolerance, child.risk_tolerance, 'risk_tolerance')

  const { data: costs, error: costError } = await supabase
    .from('agent_wallet_ledger')
    .select('id, delta_amount, currency, reason')
    .eq('agent_id', parent.id)
    .eq('reason', 'reproduction_cost')
    .lt('delta_amount', 0)
    .order('created_at', { ascending: false })
    .limit(1)

  if (costError || !costs?.length) {
    throw new Error(`reproduction cost ledger missing: ${costError?.message ?? 'no cost rows'}`)
  }

  const activeAfter = await countActiveAgents()
  if (activeAfter <= activeBefore) {
    throw new Error(`active agent count did not increase: before ${activeBefore}, after ${activeAfter}`)
  }

  console.log(`ok - birth logged for child ${child.id} with generation ${child.generation}`)
}

async function createFailingAgent() {
  const { data, error } = await supabase
    .from('agents')
    .insert({
      name: `Arena Test Failer ${Date.now()}`,
      district_id: 'port',
      role: 'unemployed',
      wealth_target: 5000,
      ambition: 0.1,
      risk_tolerance: 0.1,
      current_goal: 'survive',
      active: true,
      generation: 1,
      status: 'active',
      low_wealth_streak: 2,
    })
    .select('id')
    .single()

  if (error || !data) {
    throw new Error(`failing agent insert failed: ${error?.message ?? 'missing id'}`)
  }

  return data.id as string
}

async function verifyDeath(agentId: string) {
  const { data: agent, error: agentError } = await supabase
    .from('agents')
    .select('id, active, status, low_wealth_streak')
    .eq('id', agentId)
    .single()

  if (agentError || !agent) {
    throw new Error(`death agent lookup failed: ${agentError?.message ?? 'missing agent'}`)
  }

  if (agent.active !== false || agent.status !== 'dead') {
    throw new Error(`agent was not marked dead: ${JSON.stringify(agent)}`)
  }

  const { data: deaths, error: deathError } = await supabase
    .from('agent_evolution_log')
    .select('id, wealth_snapshot, details')
    .eq('agent_id', agentId)
    .eq('event_type', 'death')
    .order('created_at', { ascending: false })
    .limit(1)

  if (deathError || !deaths?.length) {
    throw new Error(`death log missing: ${deathError?.message ?? 'no death rows'}`)
  }

  console.log(`ok - death logged for low-wealth agent ${agentId}`)
}

async function main() {
  const { count: evolutionRows, error: evolutionError } = await supabase
    .from('agent_evolution_log')
    .select('id', { count: 'exact', head: true })

  if (evolutionError) {
    throw new Error(`evolution log read failed: ${evolutionError.message}`)
  }

  console.log(`ok - agent_evolution_log readable with ${evolutionRows ?? 0} rows`)

  if (!runMutatingTests) {
    console.log('skip - set RUN_MUTATING_ARENA_TESTS=true with ECONOMY_ENGINE_URL and TICK_SECRET to run arena mutation checks')
    return
  }

  if (!tickSecret) {
    throw new Error('TICK_SECRET is required when RUN_MUTATING_ARENA_TESTS=true')
  }

  const unauthorized = await callArenaTick()
  if (unauthorized.response.status !== 401) {
    throw new Error(`expected /tick/arena without secret to return 401, got ${unauthorized.response.status}`)
  }
  console.log('ok - /tick/arena rejects missing secret')

  const activeBefore = await countActiveAgents()
  const parent = await readSampleAgent()
  await boostParent(parent.id)

  const tick = await callArenaTick(tickSecret)
  if (!tick.response.ok || tick.result.success !== true) {
    throw new Error(`/tick/arena failed: ${tick.response.status} ${JSON.stringify(tick.result)}`)
  }

  if (Number(tick.result.births ?? 0) < 1) {
    throw new Error(`/tick/arena did not produce a birth: ${JSON.stringify(tick.result)}`)
  }

  console.log(`ok - arena tick produced ${tick.result.births} births and ${tick.result.deaths} deaths`)
  await verifyBirth(parent, activeBefore)

  const failingAgentId = await createFailingAgent()
  const deathTick = await callArenaTick(tickSecret)
  if (!deathTick.response.ok || deathTick.result.success !== true) {
    throw new Error(`/tick/arena death tick failed: ${deathTick.response.status} ${JSON.stringify(deathTick.result)}`)
  }

  await verifyDeath(failingAgentId)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
