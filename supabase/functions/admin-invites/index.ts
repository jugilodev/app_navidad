import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (request: Request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (request.method !== 'POST') {
    return Response.json({ error: 'Método no permitido.' }, { status: 405, headers: corsHeaders })
  }

  const authorization = request.headers.get('Authorization')
  const token = authorization?.replace(/^Bearer\s+/i, '')
  if (!token) {
    return Response.json({ error: 'Inicia una sesión para continuar.' }, { status: 401, headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return Response.json({ error: 'La función no está configurada en Supabase.' }, { status: 500, headers: corsHeaders })
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: { user }, error: authError } = await authClient.auth.getUser()
  if (authError || !user) {
    return Response.json({ error: 'La sesión ya no es válida. Recarga la página e inténtalo de nuevo.' }, { status: 401, headers: corsHeaders })
  }

  let action: unknown
  let memberId: unknown
  try {
    const body = await request.json()
    action = body.action
    memberId = body.member_id
  } catch {
    return Response.json({ error: 'No se pudo leer la solicitud.' }, { status: 400, headers: corsHeaders })
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: isAdmin, error: authorizationError } = await serviceClient.rpc('is_family_admin', {
    p_user_id: user.id,
  })
  if (authorizationError) {
    return Response.json({ error: authorizationError.message }, { status: 500, headers: corsHeaders })
  }
  if (!isAdmin) {
    return Response.json({ error: 'Solo Juanene puede gestionar las invitaciones.' }, { status: 403, headers: corsHeaders })
  }

  if (action === 'status') {
    const { data, error } = await serviceClient.rpc('get_family_invite_status', {
      p_admin_user_id: user.id,
    })
    if (error) {
      return Response.json({ error: error.message }, { status: 400, headers: corsHeaders })
    }
    return Response.json({ invites: data }, { headers: corsHeaders })
  }

  if (action === 'create' && typeof memberId === 'string') {
    const { data, error } = await serviceClient.rpc('create_family_invite', {
      p_admin_user_id: user.id,
      p_member_id: memberId,
    })
    if (error) {
      return Response.json({ error: error.message }, { status: 400, headers: corsHeaders })
    }
    return Response.json({ invite: data }, { headers: corsHeaders })
  }

  return Response.json({ error: 'La acción solicitada no es válida.' }, { status: 400, headers: corsHeaders })
})
