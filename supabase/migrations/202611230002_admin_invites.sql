alter table public.family_members
add column is_admin boolean not null default false;

update public.family_members
set is_admin = true
where name = 'Juanene';

create or replace function private.has_current_identity()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.member_identity identity
    where identity.user_id = auth.uid()
  );
$$;

drop policy if exists "Family members are visible to signed-in guests"
on public.family_members;
create policy "Family members are visible to linked guests"
on public.family_members for select to authenticated
using (private.has_current_identity());

drop policy if exists "The family can see wishlists"
on public.wishlists;
create policy "Linked guests can see family wishlists"
on public.wishlists for select to authenticated
using (private.has_current_identity());

create or replace view public.public_questions
with (security_barrier = true)
as
select id, recipient_id, body, answer, created_at, answered_at
from private.questions
where private.has_current_identity();

revoke all on function private.has_current_identity() from public, anon, authenticated;
grant execute on function private.has_current_identity() to authenticated;

create or replace function public.is_family_admin(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.member_identity identity
    join public.family_members member on member.id = identity.member_id
    where identity.user_id = p_user_id
      and member.is_admin
  );
$$;

create or replace function public.get_family_invite_status(p_admin_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_family_admin(p_admin_user_id) then
    raise exception 'Solo Juanene puede gestionar las invitaciones.';
  end if;

  return coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'id', member.id,
          'name', member.name,
          'has_invite', access_code.member_id is not null,
          'activated', exists (
            select 1
            from private.member_identity identity
            where identity.member_id = member.id
          )
        )
        order by member.name
      )
      from public.family_members member
      left join private.member_access_codes access_code on access_code.member_id = member.id
      where not member.is_admin
    ),
    '[]'::jsonb
  );
end;
$$;

create or replace function public.create_family_invite(p_admin_user_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_member_name text;
begin
  if not public.is_family_admin(p_admin_user_id) then
    raise exception 'Solo Juanene puede gestionar las invitaciones.';
  end if;

  perform 1
  from private.group_settings
  where singleton
  for update;

  select member.name
  into v_member_name
  from public.family_members member
  where member.id = p_member_id
    and not member.is_admin;

  if v_member_name is null then
    raise exception 'No encontramos a esa persona para crear su invitación.';
  end if;

  v_code := upper(encode(extensions.gen_random_bytes(12), 'hex'));

  insert into private.member_access_codes (member_id, code_hash, bound_user_id)
  values (
    p_member_id,
    encode(extensions.digest(v_code, 'sha256'), 'hex'),
    null
  )
  on conflict (member_id) do update
  set code_hash = excluded.code_hash,
      bound_user_id = null;

  delete from private.member_identity
  where member_id = p_member_id;

  return jsonb_build_object(
    'member_id', p_member_id,
    'member_name', v_member_name,
    'code', v_code
  );
end;
$$;

revoke all on function public.is_family_admin(uuid) from public, anon, authenticated;
revoke all on function public.get_family_invite_status(uuid) from public, anon, authenticated;
revoke all on function public.create_family_invite(uuid, uuid) from public, anon, authenticated;
grant execute on function public.is_family_admin(uuid) to service_role;
grant execute on function public.get_family_invite_status(uuid) to service_role;
grant execute on function public.create_family_invite(uuid, uuid) to service_role;
