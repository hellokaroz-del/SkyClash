-- SkyClash town lobby: profiles + world chat
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Safe to run more than once.

-- 1) Player profiles (one row per signed-in player)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'ผู้เล่น' check (char_length(name) between 1 and 16),
  level int not null default 1,
  exp int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- players may only write their own name; level/exp stay server-side for later anti-cheat
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant insert (id, name) on public.profiles to authenticated;
grant update (name) on public.profiles to authenticated;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select to authenticated using (true);
drop policy if exists "insert own profile" on public.profiles;
create policy "insert own profile" on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create or replace function public.profiles_touch() returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  new.name := btrim(new.name);
  return new;
end $$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before insert or update on public.profiles for each row execute function public.profiles_touch();

-- 2) World chat
create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null default '',
  body text not null check (char_length(body) between 1 and 200),
  channel text not null default 'world' check (channel in ('world')),
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_created_idx on public.chat_messages (created_at desc);
alter table public.chat_messages enable row level security;

revoke all on public.chat_messages from anon, authenticated;
grant select on public.chat_messages to authenticated;
grant insert (body, channel) on public.chat_messages to authenticated;

drop policy if exists "chat readable" on public.chat_messages;
create policy "chat readable" on public.chat_messages for select to authenticated using (true);
drop policy if exists "chat insert own" on public.chat_messages;
create policy "chat insert own" on public.chat_messages for insert to authenticated with check (user_id = auth.uid());

-- sender and name come from the server, at most 1 message per 2 seconds, messages kept 3 days
create or replace function public.chat_before_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare pname text;
begin
  new.user_id := auth.uid();
  new.created_at := now();
  new.body := btrim(new.body);
  select name into pname from public.profiles where id = new.user_id;
  if pname is null then raise exception 'no_profile'; end if;
  new.name := pname;
  if exists (select 1 from public.chat_messages where user_id = new.user_id and created_at > now() - interval '2 seconds') then
    raise exception 'slow_down';
  end if;
  delete from public.chat_messages where created_at < now() - interval '3 days';
  return new;
end $$;
revoke execute on function public.chat_before_insert() from public, anon, authenticated;
drop trigger if exists chat_before_insert on public.chat_messages;
create trigger chat_before_insert before insert on public.chat_messages for each row execute function public.chat_before_insert();

-- 3) Live updates for new chat messages
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages') then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;
