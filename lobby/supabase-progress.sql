-- Ages of Aether lobby: player progress (tutorial reward, EXP log)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Safe to run more than once. Run after supabase-character.sql.

-- 1) new characters play the tutorial once. Players who already exist when this column is first added count as done,
--    so only characters made from now on are sent into the tutorial.
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'tutorial_done') then
    alter table public.profiles add column tutorial_done boolean not null default true;
    alter table public.profiles alter column tutorial_done set default false;
  end if;
end $$;

-- 2) every EXP change is written here (who, from what, how much, level and EXP after). Players can read their own rows;
--    only the server functions below write them.
create table if not exists public.exp_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  source text not null,
  exp int not null,
  level_after int not null,
  exp_after int not null,
  created_at timestamptz not null default now()
);
alter table public.exp_log enable row level security;
grant select on public.exp_log to authenticated;
drop policy if exists "read own exp log" on public.exp_log;
create policy "read own exp log" on public.exp_log for select to authenticated using (user_id = auth.uid());

-- 3) finishing the tutorial gives exactly the EXP from level 1 to 2 (exp-table-v3: 1,000), once per character.
--    The EXP bar counts EXP inside the current level, so the player lands on level 2 with 0 EXP.
create or replace function public.finish_tutorial() returns public.profiles
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid() for update;
  if not found then raise exception 'no_profile'; end if;
  if p.tutorial_done then return p; end if;
  update public.profiles set tutorial_done = true,
    level = greatest(level, 2),
    exp = case when level < 2 then 0 else exp end
  where id = auth.uid() returning * into p;
  insert into public.exp_log (user_id, source, exp, level_after, exp_after) values (p.id, 'tutorial', 1000, p.level, p.exp);
  return p;
end $$;
revoke all on function public.finish_tutorial() from public;
grant execute on function public.finish_tutorial() to authenticated;
