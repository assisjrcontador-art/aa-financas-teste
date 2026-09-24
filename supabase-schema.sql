-- A&A Finanças: execute no SQL Editor de um projeto Supabase.
create extension if not exists pgcrypto;

create table if not exists households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'A&A',
  created_at timestamptz not null default now()
);

create table if not exists household_members (
  household_id uuid not null references households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (display_name in ('Assis','Andressa')),
  primary key (household_id,user_id)
);

create table if not exists finance_state (
  household_id uuid primary key references households(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table households enable row level security;
alter table household_members enable row level security;
alter table finance_state enable row level security;

create policy "members read household" on households for select using (
  exists(select 1 from household_members m where m.household_id=id and m.user_id=auth.uid())
);
create policy "members read members" on household_members for select using (
  exists(select 1 from household_members m where m.household_id=household_id and m.user_id=auth.uid())
);
create policy "members read state" on finance_state for select using (
  exists(select 1 from household_members m where m.household_id=household_id and m.user_id=auth.uid())
);
create policy "members update state" on finance_state for update using (
  exists(select 1 from household_members m where m.household_id=household_id and m.user_id=auth.uid())
) with check (
  exists(select 1 from household_members m where m.household_id=household_id and m.user_id=auth.uid())
);

alter publication supabase_realtime add table finance_state;
