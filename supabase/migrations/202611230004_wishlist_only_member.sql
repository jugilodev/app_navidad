begin;

alter table public.family_members
  add column if not exists participates_in_draw boolean not null default true;

update public.family_members
set participates_in_draw = false
where name = 'Tomas';

create or replace function private.find_assignment(
  p_remaining_givers uuid[],
  p_used_recipients uuid[],
  p_assignments jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_giver uuid;
  v_recipient uuid;
  v_result jsonb;
begin
  if cardinality(p_remaining_givers) = 0 then
    return p_assignments;
  end if;

  select giver.id
  into v_giver
  from public.family_members giver
  where giver.id = any (p_remaining_givers)
    and giver.participates_in_draw
  order by (
    select count(*)
    from public.family_members recipient
    where recipient.participates_in_draw
      and recipient.id <> giver.id
      and not (recipient.id = any (p_used_recipients))
      and not exists (
        select 1
        from private.blocked_pairs blocked
        where blocked.giver_id = giver.id
          and blocked.recipient_id = recipient.id
      )
  ), random()
  limit 1;

  for v_recipient in
    select recipient.id
    from public.family_members recipient
    where recipient.participates_in_draw
      and recipient.id <> v_giver
      and not (recipient.id = any (p_used_recipients))
      and not exists (
        select 1
        from private.blocked_pairs blocked
        where blocked.giver_id = v_giver
          and blocked.recipient_id = recipient.id
      )
    order by random()
  loop
    v_result := private.find_assignment(
      array_remove(p_remaining_givers, v_giver),
      array_append(p_used_recipients, v_recipient),
      p_assignments || jsonb_build_object(v_giver::text, v_recipient::text)
    );
    if v_result is not null then
      return v_result;
    end if;
  end loop;

  return null;
end;
$$;

do $$
declare
  v_used_recipients uuid[];
  v_assignments jsonb;
  v_remaining_givers uuid[];
  v_complete_assignment jsonb;
  v_existing_givers uuid[];
  v_release_givers uuid[];
  v_release_count integer;
  v_existing_count integer;
  v_mask integer;
  v_index integer;
  v_found_assignment boolean := false;
begin
  perform 1
  from private.group_settings
  where singleton
  for update;

  delete from private.draw_assignments assignment
  using public.family_members giver, public.family_members recipient
  where assignment.giver_id = giver.id
    and assignment.recipient_id = recipient.id
    and (not giver.participates_in_draw or not recipient.participates_in_draw);

  select coalesce(array_agg(assignment.giver_id order by assignment.giver_id), '{}'::uuid[])
  into v_existing_givers
  from private.draw_assignments assignment
  join public.family_members giver on giver.id = assignment.giver_id
  where giver.participates_in_draw;
  v_existing_count := cardinality(v_existing_givers);

  for v_release_count in 0..v_existing_count loop
    for v_mask in 0..((1 << v_existing_count) - 1) loop
      v_release_givers := '{}'::uuid[];
      for v_index in 1..v_existing_count loop
        if (v_mask & (1 << (v_index - 1))) <> 0 then
          v_release_givers := array_append(v_release_givers, v_existing_givers[v_index]);
        end if;
      end loop;

      if cardinality(v_release_givers) <> v_release_count then
        continue;
      end if;

      select
        coalesce(array_agg(assignment.recipient_id), '{}'::uuid[]),
        coalesce(jsonb_object_agg(assignment.giver_id::text, assignment.recipient_id::text), '{}'::jsonb)
      into v_used_recipients, v_assignments
      from private.draw_assignments assignment
      where not (assignment.giver_id = any (v_release_givers));

      select coalesce(array_agg(member.id), '{}'::uuid[])
      into v_remaining_givers
      from public.family_members member
      where member.participates_in_draw
        and (
          member.id = any (v_release_givers)
          or not exists (
            select 1
            from private.draw_assignments assignment
            where assignment.giver_id = member.id
          )
        );

      v_complete_assignment := private.find_assignment(
        v_remaining_givers,
        v_used_recipients,
        v_assignments
      );

      if v_complete_assignment is not null then
        delete from private.draw_assignments assignment
        where assignment.giver_id = any (v_release_givers);

        insert into private.draw_assignments (giver_id, recipient_id)
        select entry.key::uuid, entry.value::uuid
        from jsonb_each_text(v_complete_assignment) entry
        where not exists (
          select 1
          from private.draw_assignments existing
          where existing.giver_id = entry.key::uuid
        );

        v_found_assignment := true;
        exit;
      end if;
    end loop;

    exit when v_found_assignment;
  end loop;

  if not v_found_assignment then
    raise exception 'No se encontró un sorteo válido para los participantes activos. La migración se revirtió sin guardar cambios.';
  end if;
end;
$$;

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
  v_participates_in_draw boolean;
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

  select member.name, member.participates_in_draw
  into v_member_name, v_participates_in_draw
  from public.family_members member
  where member.id = v_member_id;

  if not v_participates_in_draw then
    return jsonb_build_object(
      'member_id', v_member_id,
      'member_name', v_member_name,
      'participates_in_draw', false,
      'recipient_id', null,
      'recipient_name', null
    );
  end if;

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
    where member.participates_in_draw
      and not exists (
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
    'participates_in_draw', true,
    'recipient_id', v_recipient_id,
    'recipient_name', v_recipient_name
  );
end;
$$;

revoke all on function public.redeem_and_draw(uuid, text) from public, anon, authenticated;
grant execute on function public.redeem_and_draw(uuid, text) to service_role;

commit;
