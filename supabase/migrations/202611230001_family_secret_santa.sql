create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.family_members (
  id uuid primary key default gen_random_uuid(),
  name text not null unique
);

create table private.group_settings (
  singleton boolean primary key default true check (singleton),
  created_at timestamptz not null default now()
);

insert into private.group_settings (singleton) values (true)
on conflict (singleton) do nothing;

create table private.member_identity (
  member_id uuid primary key references public.family_members (id) on delete cascade,
  user_id uuid unique
);

create table private.member_access_codes (
  member_id uuid primary key references public.family_members (id) on delete cascade,
  code_hash text not null unique,
  bound_user_id uuid unique
);

create table private.blocked_pairs (
  giver_id uuid not null references public.family_members (id) on delete cascade,
  recipient_id uuid not null references public.family_members (id) on delete cascade,
  primary key (giver_id, recipient_id),
  check (giver_id <> recipient_id)
);

create table private.draw_assignments (
  giver_id uuid primary key references public.family_members (id) on delete cascade,
  recipient_id uuid not null unique references public.family_members (id) on delete cascade,
  created_at timestamptz not null default now(),
  check (giver_id <> recipient_id)
);

create table public.wishlists (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.family_members (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 120),
  url text check (url is null or char_length(url) <= 2048),
  approximate_price numeric(10, 2) check (approximate_price is null or approximate_price >= 0),
  description text not null default '' check (char_length(description) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table private.questions (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.family_members (id) on delete cascade,
  author_id uuid not null references public.family_members (id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 1000),
  answer text check (answer is null or char_length(answer) <= 1000),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  check (author_id <> recipient_id)
);

create index wishlists_owner_id_idx on public.wishlists (owner_id);
create index questions_recipient_created_idx on private.questions (recipient_id, created_at desc);

create or replace function private.is_current_member(p_member_id uuid)
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
      and identity.member_id = p_member_id
  );
$$;

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
  order by (
    select count(*)
    from public.family_members recipient
    where recipient.id <> giver.id
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
    where recipient.id <> v_giver
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
  v_bound_user_id uuid;
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

    select access_code.member_id, access_code.bound_user_id
    into v_code_member_id, v_bound_user_id
    from private.member_access_codes access_code
    where access_code.code_hash = encode(extensions.digest(upper(trim(p_code)), 'sha256'), 'hex')
    for update;

    if v_code_member_id is null then
      raise exception 'El código no es válido. Revísalo e inténtalo de nuevo.';
    end if;
    if v_bound_user_id is not null and v_bound_user_id <> p_user_id then
      raise exception 'Este código ya se utilizó en otro dispositivo.';
    end if;

    v_member_id := v_code_member_id;
    insert into private.member_identity (member_id, user_id)
    values (v_member_id, p_user_id);
    update private.member_access_codes
    set bound_user_id = p_user_id
    where member_id = v_member_id;
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

create or replace function public.ask_question(p_recipient_id uuid, p_body text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_author_id uuid;
  v_question_id uuid;
begin
  select identity.member_id into v_author_id
  from private.member_identity identity
  where identity.user_id = auth.uid();

  if v_author_id is null then
    raise exception 'Canjea tu código privado antes de enviar preguntas.';
  end if;
  if p_recipient_id = v_author_id then
    raise exception 'No puedes enviarte una pregunta a ti mismo.';
  end if;
  if char_length(trim(coalesce(p_body, ''))) not between 1 and 1000 then
    raise exception 'La pregunta debe tener entre 1 y 1000 caracteres.';
  end if;

  insert into private.questions (recipient_id, author_id, body)
  values (p_recipient_id, v_author_id, trim(p_body))
  returning id into v_question_id;

  return v_question_id;
end;
$$;

create or replace function public.answer_question(p_question_id uuid, p_answer text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_member_id uuid;
begin
  select identity.member_id into v_member_id
  from private.member_identity identity
  where identity.user_id = auth.uid();

  if v_member_id is null then
    raise exception 'Canjea tu código privado antes de responder.';
  end if;
  if char_length(trim(coalesce(p_answer, ''))) not between 1 and 1000 then
    raise exception 'La respuesta debe tener entre 1 y 1000 caracteres.';
  end if;

  update private.questions
  set answer = trim(p_answer), answered_at = now()
  where id = p_question_id
    and recipient_id = v_member_id;

  if not found then
    raise exception 'No encontramos esa pregunta para tu perfil.';
  end if;
end;
$$;

create view public.public_questions
with (security_barrier = true)
as
select id, recipient_id, body, answer, created_at, answered_at
from private.questions;

alter table public.family_members enable row level security;
create policy "Family members are visible to signed-in guests"
on public.family_members for select to authenticated using (true);

alter table public.wishlists enable row level security;
create policy "The family can see wishlists"
on public.wishlists for select to authenticated using (true);
create policy "Members can create their own wishlist items"
on public.wishlists for insert to authenticated
with check (private.is_current_member(owner_id));
create policy "Members can edit their own wishlist items"
on public.wishlists for update to authenticated
using (private.is_current_member(owner_id))
with check (private.is_current_member(owner_id));
create policy "Members can remove their own wishlist items"
on public.wishlists for delete to authenticated
using (private.is_current_member(owner_id));

grant select on public.family_members, public.wishlists, public.public_questions to authenticated;
grant insert, update, delete on public.wishlists to authenticated;
revoke all on function public.ask_question(uuid, text) from public, anon;
revoke all on function public.answer_question(uuid, text) from public, anon;
grant execute on function public.ask_question(uuid, text) to authenticated;
grant execute on function public.answer_question(uuid, text) to authenticated;
revoke all on function public.redeem_and_draw(uuid, text) from public, anon, authenticated;
grant execute on function public.redeem_and_draw(uuid, text) to service_role;
revoke all on function private.find_assignment(uuid[], uuid[], jsonb) from public, anon, authenticated, service_role;
revoke all on function private.is_current_member(uuid) from public, anon, authenticated;
grant execute on function private.is_current_member(uuid) to authenticated;
grant usage on schema private to authenticated;
grant select on public.family_members to authenticated;
