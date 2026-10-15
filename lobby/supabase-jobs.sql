-- Ages of Aether lobby: skill levels and the skills taken into battle (the bag's Jobs tab)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Safe to run more than once. Run after supabase-character.sql.

-- each player's skills, per job: { "<job>": { "lv": { "<skill id>": 1-5 }, "load": { "s1".."s6", "b", "p1", "p2": "<skill id>" } } }
alter table public.profiles add column if not exists skills jsonb not null default '{}'::jsonb;
grant update (skills) on public.profiles to authenticated;

-- skill points: 1 per level after level 1, for each job. Every skill is Lv 1 to 5; a player can never spend more than they have.
create or replace function public.profiles_skills_check() returns trigger language plpgsql set search_path = public as $$
declare
  job text; body jsonb; sk text; lv jsonb; spent int;
begin
  if new.skills is null or jsonb_typeof(new.skills) <> 'object' then raise exception 'bad_skills'; end if;
  if pg_column_size(new.skills) > 20000 then raise exception 'bad_skills'; end if;
  for job, body in select * from jsonb_each(new.skills) loop
    if jsonb_typeof(body) <> 'object' then raise exception 'bad_skills'; end if;
    spent := 0;
    if body ? 'lv' then
      if jsonb_typeof(body->'lv') <> 'object' then raise exception 'bad_skills'; end if;
      for sk, lv in select * from jsonb_each(body->'lv') loop
        if jsonb_typeof(lv) <> 'number' or (lv::text)::numeric not between 1 and 5 then raise exception 'bad_skill_level'; end if;
        spent := spent + (lv::text)::int - 1;
      end loop;
    end if;
    if spent > greatest(coalesce(new.level, 1), 1) - 1 then raise exception 'not_enough_skill_points'; end if;
  end loop;
  return new;
end $$;
drop trigger if exists profiles_skills_check on public.profiles;
create trigger profiles_skills_check before insert or update of skills on public.profiles for each row execute function public.profiles_skills_check();
