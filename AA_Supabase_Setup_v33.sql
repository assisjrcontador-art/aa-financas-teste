-- A&A Finanças v33 — banco compartilhado seguro
-- Execute uma única vez no SQL Editor do projeto Supabase.

create extension if not exists pgcrypto;

create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'A&A Finanças',
  invite_hash text not null unique,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (display_name in ('Assis','Andressa')),
  joined_at timestamptz not null default now(),
  primary key (household_id,user_id),
  unique (household_id,display_name)
);

create table if not exists public.finance_state (
  household_id uuid primary key references public.households(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.finance_state enable row level security;

create or replace function public.is_household_member(p_household_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.household_members
    where household_id=p_household_id and user_id=auth.uid()
  );
$$;

revoke all on function public.is_household_member(uuid) from public;
grant execute on function public.is_household_member(uuid) to authenticated;

drop policy if exists "members read household" on public.households;
create policy "members read household" on public.households
for select to authenticated using (public.is_household_member(id));

drop policy if exists "members read membership" on public.household_members;
create policy "members read membership" on public.household_members
for select to authenticated using (public.is_household_member(household_id));

drop policy if exists "members read finance" on public.finance_state;
create policy "members read finance" on public.finance_state
for select to authenticated using (public.is_household_member(household_id));

create or replace function public.create_household(
  p_display_name text,
  p_invite_code text,
  p_payload jsonb
)
returns table(household_id uuid, revision bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_display_name not in ('Assis','Andressa') then raise exception 'INVALID_NAME'; end if;
  if length(trim(p_invite_code)) < 6 then raise exception 'CODE_TOO_SHORT'; end if;
  if exists(select 1 from public.household_members where user_id=auth.uid()) then
    raise exception 'ALREADY_LINKED';
  end if;

  insert into public.households(name,invite_hash,created_by)
  values('A&A Finanças',crypt(upper(trim(p_invite_code)),gen_salt('bf')),auth.uid())
  returning id into v_household;

  insert into public.household_members(household_id,user_id,display_name)
  values(v_household,auth.uid(),p_display_name);

  insert into public.finance_state(household_id,payload,revision,updated_by)
  values(v_household,coalesce(p_payload,'{}'::jsonb),1,auth.uid());

  return query select v_household,1::bigint;
end;
$$;

create or replace function public.join_household(
  p_display_name text,
  p_invite_code text
)
returns table(household_id uuid, revision bigint, payload jsonb)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_household uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_display_name not in ('Assis','Andressa') then raise exception 'INVALID_NAME'; end if;
  if exists(select 1 from public.household_members where user_id=auth.uid()) then
    raise exception 'ALREADY_LINKED';
  end if;

  select id into v_household from public.households
  where invite_hash=crypt(upper(trim(p_invite_code)),invite_hash)
  limit 1;
  if v_household is null then raise exception 'INVALID_CODE'; end if;

  -- O mesmo nome pode recuperar o acesso após reinstalação ou limpeza do navegador.
  insert into public.household_members(household_id,user_id,display_name)
  values(v_household,auth.uid(),p_display_name)
  on conflict (household_id,display_name)
  do update set user_id=excluded.user_id, joined_at=now();

  return query
  select f.household_id,f.revision,f.payload
  from public.finance_state f where f.household_id=v_household;
end;
$$;

create or replace function public.my_finance_state()
returns table(household_id uuid, revision bigint, payload jsonb, updated_at timestamptz)
language sql
security definer
stable
set search_path = public
as $$
  select f.household_id,f.revision,f.payload,f.updated_at
  from public.finance_state f
  join public.household_members m on m.household_id=f.household_id
  where m.user_id=auth.uid()
  limit 1;
$$;

create or replace function public.save_finance_state(
  p_household_id uuid,
  p_expected_revision bigint,
  p_payload jsonb
)
returns table(saved boolean, revision bigint, payload jsonb)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_revision bigint;
begin
  if not public.is_household_member(p_household_id) then raise exception 'ACCESS_DENIED'; end if;

  update public.finance_state
  set payload=p_payload,
      revision=finance_state.revision+1,
      updated_at=now(),
      updated_by=auth.uid()
  where household_id=p_household_id and finance_state.revision=p_expected_revision
  returning finance_state.revision into v_revision;

  if v_revision is not null then
    return query select true,v_revision,p_payload;
  else
    return query
    select false,f.revision,f.payload from public.finance_state f
    where f.household_id=p_household_id;
  end if;
end;
$$;

revoke all on function public.create_household(text,text,jsonb) from public;
revoke all on function public.join_household(text,text) from public;
revoke all on function public.my_finance_state() from public;
revoke all on function public.save_finance_state(uuid,bigint,jsonb) from public;
grant execute on function public.create_household(text,text,jsonb) to authenticated;
grant execute on function public.join_household(text,text) to authenticated;
grant execute on function public.my_finance_state() to authenticated;
grant execute on function public.save_finance_state(uuid,bigint,jsonb) to authenticated;

grant usage on schema public to authenticated;
grant select on public.households,public.household_members,public.finance_state to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='finance_state'
  ) then
    alter publication supabase_realtime add table public.finance_state;
  end if;
end $$;

alter table public.finance_state replica identity full;
