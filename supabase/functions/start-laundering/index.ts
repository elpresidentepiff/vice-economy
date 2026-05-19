import { createClient } from '@supabase/supabase-js'

type LaunderingBody = {
  amount?: unknown
  business_id?: unknown
  player_id?: unknown
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

function parseAmount(value: unknown): number {
  if (typeof value === 'number' && Number.isSafeInteger(value)) {
    return value
  }

  if (typeof value === 'string' && /^\d+$/.test(value)) {
    return Number.parseInt(value, 10)
  }

  return Number.NaN
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
    const publishableKey = getSupabasePublishableKey()

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

    const body = await req.json().catch(() => ({})) as LaunderingBody
    if (typeof body.business_id !== 'string' || body.business_id.trim().length === 0) {
      return jsonResponse({ success: false, error: 'invalid_business_id' }, 400)
    }

    const amount = parseAmount(body.amount)
    if (!Number.isSafeInteger(amount) || amount < 1) {
      return jsonResponse({ success: false, error: 'invalid_amount' }, 400)
    }

    const caller = createClient(supabaseUrl, publishableKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
      global: {
        headers: {
          Authorization: authHeader,
        },
      },
    })

    const { data: result, error: rpcError } = await caller.rpc('start_laundering', {
      p_player_id: authData.user.id,
      p_business_id: body.business_id.trim(),
      p_amount: amount,
    })

    if (rpcError) {
      return jsonResponse({
        success: false,
        error: 'laundering_failed',
        detail: rpcError.message,
      }, 400)
    }

    return jsonResponse(result as Record<string, unknown>, 200)
  } catch (error) {
    console.error(error)
    return jsonResponse({ success: false, error: 'internal_error' }, 500)
  }
})

