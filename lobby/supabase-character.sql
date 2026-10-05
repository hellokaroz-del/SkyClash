-- Ages of Aether lobby: character creation (job + unique names)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Safe to run more than once. Run after supabase-setup.sql and supabase-chat-channels.sql.

-- 1) each player's job, picked once on the character creation screen
alter table public.profiles add column if not exists job text
  check (job in ('blade', 'mage', 'archer', 'cleric', 'thief', 'merchant', 'doram'));
grant insert (id, name, job) on public.profiles to authenticated;
grant update (job) on public.profiles to authenticated;

-- a job can be set once (players from before this update pick theirs once), never changed by the player afterwards
create or replace function public.profiles_job_lock() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and old.job is not null and new.job is distinct from old.job then
    raise exception 'job_locked';
  end if;
  return new;
end $$;
drop trigger if exists profiles_job_lock on public.profiles;
create trigger profiles_job_lock before update on public.profiles for each row execute function public.profiles_job_lock();

-- 2) in-game names are unique, ignoring upper/lower case
-- if this line fails with "could not create unique index", two players already share a name: rename one in Table Editor, then run again
create unique index if not exists profiles_name_unique on public.profiles (lower(name));
