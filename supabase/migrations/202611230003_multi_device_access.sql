alter table private.member_identity
  drop constraint member_identity_pkey,
  alter column user_id set not null,
  add primary key (member_id, user_id);

create or replace function public.redeem_and_draw(p_user_id uuid, p_code text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
  v_member_name text;
  v_recipient_id uuid;
  v_recipient_name text;
  v_code_member_id uuid;
  v_assignments jsonb;
  v_used_recipients uuid[];
  v_remaining_givers uuid[];
  v_complete_assignment jsonb;
begin
  if p_user_id is null then
    raise exception 'Se requiere una sesión válida.';
  end if;

  perform 1
  from private.group_settings
  where singleton
  for update;

  select identity.member_id
  into v_member_id
  from private.member_identity identity
  where identity.user_id = p_user_id
  for update;

  if v_member_id is not null then
    if p_code is not null then
      select access_code.member_id
      into v_code_member_id
      from private.member_access_codes access_code
      where access_code.code_hash = encode(extensions.digest(upper(trim(p_code)), 'sha256'), 'hex');
      if v_code_member_id is distinct from v_member_id then
        raise exception 'Este acceso ya está vinculado a otra persona.';
      end if;
    end if;
  else
    if p_code is null then
      return null;
    end if;
    if char_length(trim(p_code)) < 8 then
      raise exception 'Introduce el código privado que recibiste.';
    end if;

    select access_code.member_id
    into v_code_member_id
    from private.member_access_codes access_code
    where access_code.code_hash = encode(extensions.digest(upper(trim(p_code)), 'sha256'), 'hex')
    for update;

    if v_code_member_id is null then
      raise exception 'El código no es válido. Revísalo e inténtalo de nuevo.';
    end if;

    v_member_id := v_code_member_id;
    insert into private.member_identity (member_id, user_id)
    values (v_member_id, p_user_id)
    on conflict (user_id) do nothing;

    select identity.member_id
    into v_member_id
    from private.member_identity identity
    where identity.user_id = p_user_id;

    if v_member_id is distinct from v_code_member_id then
      raise exception 'Este navegador ya está vinculado a otra persona.';
    end if;
  end if;

  select member.name
  into v_member_name
  from public.family_members member
  where member.id = v_member_id;

  select assignment.recipient_id, recipient.name
  into v_recipient_id, v_recipient_name
  from private.draw_assignments assignment
  join public.family_members recipient on recipient.id = assignment.recipient_id
  where assignment.giver_id = v_member_id;

  if v_recipient_id is null then
    select
      coalesce(array_agg(assignment.recipient_id), '{}'::uuid[]),
      coalesce(jsonb_object_agg(assignment.giver_id::text, assignment.recipient_id::text), '{}'::jsonb)
    into v_used_recipients, v_assignments
    from private.draw_assignments assignment;

    select coalesce(array_agg(member.id), '{}'::uuid[])
    into v_remaining_givers
    from public.family_members member
    where not exists (
      select 1
      from private.draw_assignments assignment
      where assignment.giver_id = member.id
    );

    v_complete_assignment := private.find_assignment(
      v_remaining_givers,
      v_used_recipients,
      v_assignments
    );

    if v_complete_assignment is null then
      raise exception 'No existe un sorteo que cumpla todas las restricciones. Pide ayuda a quien organiza.';
    end if;

    v_recipient_id := (v_complete_assignment ->> v_member_id::text)::uuid;
    if v_recipient_id is null then
      raise exception 'No se pudo completar tu asignación. Inténtalo de nuevo.';
    end if;

    insert into private.draw_assignments (giver_id, recipient_id)
    values (v_member_id, v_recipient_id);

    select member.name
    into v_recipient_name
    from public.family_members member
    where member.id = v_recipient_id;
  end if;

  return jsonb_build_object(
    'member_id', v_member_id,
    'member_name', v_member_name,
    'recipient_id', v_recipient_id,
    'recipient_name', v_recipient_name
  );
end;
$$;

revoke all on function public.redeem_and_draw(uuid, text) from public, anon, authenticated;
grant execute on function public.redeem_and_draw(uuid, text) to service_role;
