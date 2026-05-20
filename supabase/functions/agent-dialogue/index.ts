import { createClient } from 'npm:@supabase/supabase-js@2'

type DialogueBody = {
  agent_id?: unknown
  message?: unknown
  session_id?: unknown
  player_id?: unknown
}

type AgentProfile = {
  id: string
  name: string
  district_id: string
  role: string
  ambition: number | string
  risk_tolerance: number | string
  personality: Record<string, unknown>
  current_goal: string | null
}

type DialogueResult = {
  reply: string
  mood: string
  intent: string
  trust_delta: number
  memory_summary: string
  provider: string
  model?: string
  response_id?: string
}

const jsonHeaders = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: jsonHeaders,
  })
}

function getRequiredEnv(name: string): string {
  const value = Deno.env.get(name)
  if (!value) {
    throw new Error(`Missing ${name}`)
  }
  return value
}

function getOptionalProvider(): string {
  return Deno.env.get('AGENT_DIALOGUE_PROVIDER')?.trim().toLowerCase() ?? 'local'
}

function getSupabasePublishableKey(): string {
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  if (anonKey) {
    return anonKey
  }

  const publishableKeys = Deno.env.get('SUPABASE_PUBLISHABLE_KEYS')
  if (publishableKeys) {
    const parsed = JSON.parse(publishableKeys) as Record<string, string>
    if (parsed.default) {
      return parsed.default
    }
  }

  throw new Error('Missing SUPABASE_ANON_KEY or SUPABASE_PUBLISHABLE_KEYS.default')
}

function cleanMessage(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null
  }

  const trimmed = value.trim()
  if (!trimmed || trimmed.length > 2000) {
    return null
  }

  return trimmed
}

function cleanUuid(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null
  }

  const trimmed = value.trim()
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(trimmed)
    ? trimmed
    : null
}

function localDialogue(agent: AgentProfile, message: string, memories: string[]): DialogueResult {
  const lowered = message.toLowerCase()
  const risk = Number(agent.risk_tolerance)
  const ambition = Number(agent.ambition)
  const mood = risk > 0.65 ? 'bold' : ambition > 0.65 ? 'hungry' : 'measured'
  const intent = lowered.includes('job') || lowered.includes('work')
    ? 'offer_work'
    : lowered.includes('price') || lowered.includes('deal')
      ? 'haggle'
      : lowered.includes('police') || lowered.includes('heat')
        ? 'warn'
        : 'inform'
  const memoryLine = memories.length > 0 ? ` Last time on my side of the street: ${memories[0]}.` : ''

  return {
    reply: `${agent.name} watches the district before answering. "${message.slice(0, 120)}" tells me you want movement, not noise. I can point you at ${agent.current_goal ?? 'survival'} in ${agent.district_id}, but clean money talks first.${memoryLine}`,
    mood,
    intent,
    trust_delta: intent === 'offer_work' ? 1 : 0,
    memory_summary: `${agent.name} discussed ${intent} with the player in ${agent.district_id}.`,
    provider: 'local',
  }
}

function extractOpenAIText(payload: Record<string, unknown>): string {
  if (typeof payload.output_text === 'string') {
    return payload.output_text
  }

  const output = payload.output
  if (!Array.isArray(output)) {
    return ''
  }

  const parts: string[] = []
  for (const item of output) {
    if (!item || typeof item !== 'object') {
      continue
    }
    const content = (item as { content?: unknown }).content
    if (!Array.isArray(content)) {
      continue
    }
    for (const part of content) {
      if (part && typeof part === 'object') {
        const text = (part as { text?: unknown }).text
        if (typeof text === 'string') {
          parts.push(text)
        }
      }
    }
  }

  return parts.join('\n')
}

async function openAIDialogue(agent: AgentProfile, message: string, memories: string[]): Promise<DialogueResult> {
  const apiKey = Deno.env.get('OPENAI_API_KEY')
  if (!apiKey) {
    return localDialogue(agent, message, memories)
  }

  const model = Deno.env.get('OPENAI_MODEL') ?? 'gpt-5.2'
  const response = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model,
      input: [
        {
          role: 'system',
          content: [
            {
              type: 'input_text',
              text: 'You are writing one short in-world NPC response for Vice Economy. Stay grounded in the agent profile, do not claim to perform real actions, and return only the requested JSON.',
            },
          ],
        },
        {
          role: 'user',
          content: [
            {
              type: 'input_text',
              text: JSON.stringify({
                agent,
                player_message: message,
                recent_memories: memories,
              }),
            },
          ],
        },
      ],
      text: {
        format: {
          type: 'json_schema',
          name: 'agent_dialogue',
          strict: true,
          schema: {
            type: 'object',
            additionalProperties: false,
            properties: {
              reply: { type: 'string' },
              mood: { type: 'string' },
              intent: { type: 'string' },
              trust_delta: { type: 'integer' },
              memory_summary: { type: 'string' },
            },
            required: ['reply', 'mood', 'intent', 'trust_delta', 'memory_summary'],
          },
        },
      },
    }),
  })

  if (!response.ok) {
    console.error(await response.text())
    return localDialogue(agent, message, memories)
  }

  const payload = await response.json() as Record<string, unknown>
  const text = extractOpenAIText(payload)
  const parsed = JSON.parse(text) as Omit<DialogueResult, 'provider' | 'model' | 'response_id'>

  return {
    ...parsed,
    provider: 'openai',
    model,
    response_id: typeof payload.id === 'string' ? payload.id : undefined,
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        ...jsonHeaders,
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
      },
    })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ success: false, error: 'method_not_allowed' }, 405)
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) {
    return jsonResponse({ success: false, error: 'missing_authorization' }, 401)
  }

  try {
    const supabaseUrl = getRequiredEnv('SUPABASE_URL')
    const serviceRoleKey = getRequiredEnv('SUPABASE_SERVICE_ROLE_KEY')
    getSupabasePublishableKey()

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    })

    const token = authHeader.slice('Bearer '.length)
    const { data: authData, error: authError } = await admin.auth.getUser(token)
    if (authError || !authData.user) {
      return jsonResponse({ success: false, error: 'invalid_authentication' }, 401)
    }

    const body = await req.json().catch(() => ({})) as DialogueBody
    const agentId = cleanUuid(body.agent_id)
    const message = cleanMessage(body.message)
    const sessionId = cleanUuid(body.session_id)

    if (!agentId) {
      return jsonResponse({ success: false, error: 'invalid_agent_id' }, 400)
    }

    if (!message) {
      return jsonResponse({ success: false, error: 'invalid_message' }, 400)
    }

    const { data: agent, error: agentError } = await admin
      .from('agents')
      .select('id, name, district_id, role, ambition, risk_tolerance, personality, current_goal')
      .eq('id', agentId)
      .eq('active', true)
      .single()

    if (agentError || !agent) {
      return jsonResponse({ success: false, error: 'agent_not_found' }, 404)
    }

    let activeSessionId = sessionId
    if (activeSessionId) {
      const { data: existingSession, error: existingError } = await admin
        .from('agent_conversation_sessions')
        .select('id')
        .eq('id', activeSessionId)
        .eq('player_id', authData.user.id)
        .eq('agent_id', agentId)
        .eq('status', 'active')
        .maybeSingle()

      if (existingError || !existingSession) {
        return jsonResponse({ success: false, error: 'session_not_found' }, 404)
      }
    } else {
      const { data: createdSession, error: sessionError } = await admin
        .from('agent_conversation_sessions')
        .insert({
          player_id: authData.user.id,
          agent_id: agentId,
          district_id: agent.district_id,
        })
        .select('id')
        .single()

      if (sessionError || !createdSession) {
        return jsonResponse({ success: false, error: 'session_create_failed', detail: sessionError?.message }, 500)
      }

      activeSessionId = createdSession.id
    }

    const { data: memoryRows } = await admin
      .from('agent_memory_events')
      .select('summary')
      .eq('agent_id', agentId)
      .eq('player_id', authData.user.id)
      .order('created_at', { ascending: false })
      .limit(5)

    const memories = (memoryRows ?? []).map((row: { summary: string }) => row.summary)
    const result = getOptionalProvider() === 'openai'
      ? await openAIDialogue(agent as AgentProfile, message, memories)
      : localDialogue(agent as AgentProfile, message, memories)

    const { error: playerMessageError } = await admin
      .from('agent_conversation_messages')
      .insert({
        session_id: activeSessionId,
        speaker: 'player',
        body: message,
        metadata: {
          ignored_player_id: body.player_id ?? null,
        },
      })

    if (playerMessageError) {
      return jsonResponse({ success: false, error: 'player_message_log_failed', detail: playerMessageError.message }, 500)
    }

    const { error: agentMessageError } = await admin
      .from('agent_conversation_messages')
      .insert({
        session_id: activeSessionId,
        speaker: 'agent',
        body: result.reply,
        mood: result.mood,
        intent: result.intent,
        metadata: {
          trust_delta: result.trust_delta,
          provider: result.provider,
          model: result.model ?? null,
          response_id: result.response_id ?? null,
        },
      })

    if (agentMessageError) {
      return jsonResponse({ success: false, error: 'agent_message_log_failed', detail: agentMessageError.message }, 500)
    }

    const { error: memoryError } = await admin.from('agent_memory_events').insert({
      agent_id: agentId,
      player_id: authData.user.id,
      memory_type: 'conversation',
      salience: Math.max(1, Math.min(10, Math.abs(result.trust_delta) + 1)),
      summary: result.memory_summary,
      metadata: {
        session_id: activeSessionId,
        mood: result.mood,
        intent: result.intent,
      },
    })

    if (memoryError) {
      return jsonResponse({ success: false, error: 'memory_log_failed', detail: memoryError.message }, 500)
    }

    const { error: eventError } = await admin.from('agent_dialogue_events').insert({
      session_id: activeSessionId,
      agent_id: agentId,
      player_id: authData.user.id,
      provider: result.provider,
      model: result.model ?? null,
      response_id: result.response_id ?? null,
    })

    if (eventError) {
      return jsonResponse({ success: false, error: 'dialogue_event_log_failed', detail: eventError.message }, 500)
    }

    return jsonResponse({
      success: true,
      session_id: activeSessionId,
      agent_id: agentId,
      reply: result.reply,
      mood: result.mood,
      intent: result.intent,
      trust_delta: result.trust_delta,
      provider: result.provider,
    })
  } catch (error) {
    console.error(error)
    return jsonResponse({ success: false, error: 'internal_error' }, 500)
  }
})
