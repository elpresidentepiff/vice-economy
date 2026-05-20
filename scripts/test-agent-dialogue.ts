import { createClient } from '@supabase/supabase-js'
import 'dotenv/config'

const supabaseUrl = process.env.SUPABASE_URL ?? 'https://ltbsxbvfsxtnharjvqcm.supabase.co'
const publishableKey = process.env.SUPABASE_ANON_KEY ?? process.env.SUPABASE_PUBLISHABLE_KEY
const testEmail = process.env.TEST_PLAYER_EMAIL
const testPassword = process.env.TEST_PLAYER_PASSWORD
const runMutatingTests = process.env.RUN_MUTATING_AGENT_DIALOGUE_TESTS === 'true'

if (!publishableKey) {
  throw new Error('SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEY is required')
}

const supabase = createClient(supabaseUrl, publishableKey, {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
})

async function readAgent() {
  const { data, error } = await supabase
    .from('agents')
    .select('id, name, role, district_id')
    .eq('active', true)
    .limit(1)
    .single()

  if (error || !data) {
    throw new Error(`agent read failed: ${error?.message ?? 'missing agent'}`)
  }

  console.log(`ok - read active agent ${data.name} (${data.role}) in ${data.district_id}`)
  return data
}

async function callDialogue(accessToken: string, agentId: string) {
  const response = await fetch(`${supabaseUrl}/functions/v1/agent-dialogue`, {
    method: 'POST',
    headers: {
      apikey: publishableKey,
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      agent_id: agentId,
      message: 'Any work around here, and how hot is the street?',
      player_id: '00000000-0000-0000-0000-000000000000',
    }),
  })

  const result = await response.json()
  return { response, result }
}

async function runDialogueTest(agentId: string) {
  if (!testEmail || !testPassword) {
    throw new Error('TEST_PLAYER_EMAIL and TEST_PLAYER_PASSWORD are required when RUN_MUTATING_AGENT_DIALOGUE_TESTS=true')
  }

  const { data: authData, error: authError } = await supabase.auth.signInWithPassword({
    email: testEmail,
    password: testPassword,
  })

  if (authError || !authData.user || !authData.session) {
    throw new Error(`auth failed: ${authError?.message ?? 'missing session'}`)
  }

  const { response, result } = await callDialogue(authData.session.access_token, agentId)
  if (!response.ok || result.success !== true) {
    throw new Error(`agent dialogue failed: ${response.status} ${JSON.stringify(result)}`)
  }

  if (!result.session_id || !result.reply || !result.intent) {
    throw new Error(`agent dialogue returned incomplete payload: ${JSON.stringify(result)}`)
  }

  console.log(`ok - dialogue reply from ${result.provider}: ${result.intent}/${result.mood}`)

  const { data: messages, error: messageError } = await supabase
    .from('agent_conversation_messages')
    .select('speaker, body')
    .eq('session_id', result.session_id)
    .order('created_at', { ascending: true })

  if (messageError || !messages || messages.length < 2) {
    throw new Error(`conversation message read failed: ${messageError?.message ?? 'missing messages'}`)
  }

  console.log(`ok - read ${messages.length} persisted dialogue messages`)

  const { data: memories, error: memoryError } = await supabase
    .from('agent_memory_events')
    .select('memory_type, summary')
    .eq('agent_id', agentId)
    .order('created_at', { ascending: false })
    .limit(1)

  if (memoryError || !memories?.length) {
    throw new Error(`agent memory read failed: ${memoryError?.message ?? 'missing memory'}`)
  }

  console.log(`ok - persisted ${memories[0].memory_type} memory`)
}

async function main() {
  const agent = await readAgent()

  if (!runMutatingTests) {
    console.log('skip - set RUN_MUTATING_AGENT_DIALOGUE_TESTS=true with test player credentials to call agent-dialogue')
    return
  }

  await runDialogueTest(agent.id)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
