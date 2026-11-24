insert into public.family_members (name, is_admin, participates_in_draw) values
  ('Tata', false, true),
  ('Luisa', false, true),
  ('Miguel', false, true),
  ('Sofia', false, true),
  ('Federico', false, true),
  ('Sebastian', false, true),
  ('Juanene', true, true),
  ('Tomas', false, false);

insert into private.blocked_pairs (giver_id, recipient_id)
select giver.id, recipient.id
from (values
  ('Tata', 'Sebastian'),
  ('Sebastian', 'Tata'),
  ('Miguel', 'Juanene'),
  ('Miguel', 'Sofia'),
  ('Sofia', 'Federico'),
  ('Federico', 'Sofia')
) as blocked(giver_name, recipient_name)
join public.family_members giver on giver.name = blocked.giver_name
join public.family_members recipient on recipient.name = blocked.recipient_name;

with code_values (name, code) as materialized (
  values ('Juanene', upper(encode(extensions.gen_random_bytes(12), 'hex')))
),
inserted_codes as (
  insert into private.member_access_codes (member_id, code_hash)
  select member.id, encode(extensions.digest(code_values.code, 'sha256'), 'hex')
  from code_values
  join public.family_members member on member.name = code_values.name
  returning member_id
)
select member.name as participante, code_values.code as codigo_privado
from code_values
join public.family_members member on member.name = code_values.name
join inserted_codes on inserted_codes.member_id = member.id
order by member.name;
