-- Ages of Aether lobby: dungeon runs and their rewards (Karoz 2026-10-16)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run more than once.
-- Run after supabase-admin.sql, supabase-items.sql and supabase-rush.sql (it uses gain_exp, egg_fill and egg_give).
--
-- A party's host presses ลุย in a dungeon room: the town asks dungeon_start for a ticket for that dungeon and level.
-- When the run ends the town sends the ticket and the result to dungeon_end, which pays a cleared run its reward:
--   ทุ่งสไลม์ ปกติ: EXP 350 and gold 250 (Karoz 2026-10-16); a run that was not cleared gets nothing
--   ทุ่งสไลม์ ยาก: 2 phases, the slime field then King สไลม์ (Karoz 2026-10-16). Clearing phase 1 only moves the ticket on to
--   phase 2 (nothing is paid); clearing the last phase pays EXP 460 and gold 330 (Karoz 2026-10-16).
-- and fills 12 eggs from the admin panel's prize list for that dungeon level (game_settings egg_pool 'dg:slime:normal').
-- dungeon_egg_pick breaks the egg the player picked and hands over its prize. A ticket pays once.

create table if not exists public.dungeon_run (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  dungeon text not null,
  lv text not null,
  created_at timestamptz not null default now(),
  result text check (result in ('win', 'loss')),
  kills int,
  ended_at timestamptz,
  gold int,
  exp int,
  prizes jsonb,
  egg_pick int
);
alter table public.dungeon_run add column if not exists phase int not null default 1; -- the phase being played
create index if not exists dungeon_run_user_idx on public.dungeon_run (user_id, created_at desc);
alter table public.dungeon_run enable row level security;
revoke all on public.dungeon_run from anon, authenticated;
-- no direct access: the eggs' contents stay hidden until one is picked

-- each dungeon level's reward for a cleared run and how many phases it has (1 when not given); a new dungeon or
-- level gets a line here
create or replace function public.dungeon_pay(p_dungeon text, p_lv text) returns jsonb
language sql immutable set search_path = public as $$
  select case p_dungeon || ':' || p_lv
    when 'slime:normal' then '{"exp": 350, "gold": 250}'::jsonb
    when 'slime:hard' then '{"exp": 460, "gold": 330, "phases": 2}'::jsonb
  end;
$$;

create or replace function public.dungeon_start(p_dungeon text, p_lv text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.dungeon_run;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if public.dungeon_pay(p_dungeon, p_lv) is null then raise exception 'no_dungeon'; end if;
  delete from public.dungeon_run where user_id = auth.uid() and ended_at is null; -- a run left before its end pays nothing
  insert into public.dungeon_run (user_id, dungeon, lv) values (auth.uid(), p_dungeon, p_lv) returning * into t;
  return jsonb_build_object('ticket', t.id);
end $$;

create or replace function public.dungeon_end(p_ticket uuid, p_result text, p_kills int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.dungeon_run; p public.profiles; pay jsonb; g int := 0; e int := 0; pz jsonb;
begin
  select * into t from public.dungeon_run where id = p_ticket and user_id = auth.uid() for update;
  if not found then raise exception 'no_ticket'; end if;
  if t.ended_at is not null then raise exception 'already_ended'; end if;
  if p_result is null or p_result not in ('win', 'loss') then raise exception 'bad_result'; end if;
  if t.created_at < now() - interval '3 hours' then raise exception 'expired'; end if;
  -- clearing 15 slimes (or King สไลม์) takes many turns: a clear sent within 30 s of the phase starting pays nothing
  if p_result = 'win' and t.created_at > now() - interval '30 seconds' then raise exception 'too_fast'; end if;
  pay := public.dungeon_pay(t.dungeon, t.lv);
  -- a cleared phase that is not the last: on to the next one, with its own 30 s clock; nothing is paid yet
  if p_result = 'win' and t.phase < coalesce((pay->>'phases')::int, 1) then
    update public.dungeon_run set phase = phase + 1, created_at = now() where id = t.id;
    return jsonb_build_object('result', 'win', 'next', t.phase + 1);
  end if;
  if p_result = 'win' then
    g := coalesce((pay->>'gold')::int, 0); e := coalesce((pay->>'exp')::int, 0);
    pz := public.egg_fill('dg:' || t.dungeon || ':' || t.lv);
  end if;
  if g > 0 then update public.profiles set gold = gold + g where id = auth.uid(); end if;
  if e > 0 then perform public.gain_exp(auth.uid(), e, 'dungeon'); end if;
  update public.dungeon_run set result = p_result, kills = greatest(0, coalesce(p_kills, 0)), ended_at = now(), gold = g, exp = e, prizes = pz where id = t.id;
  select * into p from public.profiles where id = auth.uid();
  return jsonb_build_object('result', p_result, 'gold', g, 'exp', e, 'eggs', coalesce(jsonb_array_length(pz), 0),
    'me', jsonb_build_object('level', p.level, 'exp', p.exp, 'gold', p.gold, 'gem', p.gem, 'coupon', p.coupon));
end $$;

-- break one of the 12 eggs (0-11): its prize goes to the player, and all 12 are shown
create or replace function public.dungeon_egg_pick(p_ticket uuid, p_index int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.dungeon_run; p public.profiles;
begin
  select * into t from public.dungeon_run where id = p_ticket and user_id = auth.uid() for update;
  if not found then raise exception 'no_ticket'; end if;
  if t.prizes is null then raise exception 'no_eggs'; end if;
  if t.egg_pick is not null then raise exception 'already_picked'; end if;
  if p_index is null or p_index < 0 or p_index >= jsonb_array_length(t.prizes) then raise exception 'bad_egg'; end if;
  update public.dungeon_run set egg_pick = p_index where id = t.id;
  perform public.egg_give(auth.uid(), t.prizes->p_index);
  select * into p from public.profiles where id = auth.uid();
  return jsonb_build_object('pick', p_index, 'won', t.prizes->p_index, 'eggs', t.prizes, 'coupon', p.coupon, 'gold', p.gold);
end $$;

revoke all on function public.dungeon_start(text, text), public.dungeon_end(uuid, text, int), public.dungeon_egg_pick(uuid, int) from public;
grant execute on function public.dungeon_start(text, text), public.dungeon_end(uuid, text, int), public.dungeon_egg_pick(uuid, int) to authenticated;
