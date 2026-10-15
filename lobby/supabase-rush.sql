-- Ages of Aether lobby: ลุย against a bot when no player turns up (Karoz 2026-10-15)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run more than once.
-- Run after supabase-match.sql, supabase-progress.sql and supabase-admin.sql.
--
-- ลุย looks for a player for 30 s. After that the town asks match_bot: the server checks the player really has waited
-- 30 s in the queue, takes them out of it and hands back a ticket for one bot match (a hard bot one level above the
-- lowest level in the team). When the match ends the town sends the ticket and the result to rush_end, which pays:
--   gold 100 x (level / 10) and EXP 200 x (level / 10), level = the lowest level in the team (Lv.17 -> x1.7, Lv.32 -> x3.2);
--   a loss or a draw gets 25% of that; a player who dealt no damage at all gets nothing, and no egg (Karoz 2026-10-15)
-- and fills 12 eggs with a random number of coupons each (between egg.rush_bot.min and .max from the admin panel's settings),
-- new for every match. egg_pick breaks the egg the player picked and adds its coupons. A ticket pays once.
-- Teams are one player for now (the game plays 1 against 1), so the lowest level in the team is the player's own.

create table if not exists public.rush_bot (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  level int not null,
  bot_level int not null,
  created_at timestamptz not null default now(),
  result text check (result in ('win', 'loss', 'draw')),
  ended_at timestamptz,
  gold int,
  exp int,
  eggs int[],
  egg_pick int
);
create index if not exists rush_bot_user_idx on public.rush_bot (user_id, created_at desc);
alter table public.rush_bot enable row level security;
revoke all on public.rush_bot from anon, authenticated;
-- no direct access: the eggs' contents stay hidden until one is picked

-- EXP from the server's own rewards (not callable by players): levels up past each level's need, Lv 100 at most
create or replace function public.gain_exp(p_id uuid, p_exp int, p_source text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare p public.profiles; lv int; ex bigint;
begin
  select * into p from public.profiles where id = p_id for update;
  if not found or coalesce(p_exp, 0) <= 0 then return p; end if;
  lv := greatest(coalesce(p.level, 1), 1); ex := greatest(coalesce(p.exp, 0), 0) + p_exp;
  while lv < 100 and ex >= public.exp_need(lv) loop ex := ex - public.exp_need(lv); lv := lv + 1; end loop;
  if lv >= 100 then lv := 100; ex := least(ex, public.exp_need(100) - 1); end if;
  update public.profiles set level = lv, exp = ex::int where id = p_id returning * into p;
  insert into public.exp_log (user_id, source, exp, level_after, exp_after) values (p_id, p_source, p_exp, p.level, p.exp);
  return p;
end $$;

-- after 30 s of ลุย with nobody found: a bot match instead (or the match, if a player turned up just now)
create or replace function public.match_bot() returns jsonb
language plpgsql security definer set search_path = public as $$
declare q public.match_queue; lv int; t public.rush_bot;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  perform pg_advisory_xact_lock(424242); -- the same lock as match_pair: a player is never paired and given a bot at once
  select * into q from public.match_queue where user_id = auth.uid() for update;
  if not found then return jsonb_build_object('status', 'none'); end if;
  if q.game_code is not null then return public.match_view(q); end if;
  if q.created_at > now() - interval '29 seconds' then raise exception 'too_soon'; end if;
  delete from public.match_queue where user_id = auth.uid();
  select greatest(1, least(100, coalesce(level, 1))) into lv from public.profiles where id = auth.uid();
  delete from public.rush_bot where user_id = auth.uid() and ended_at is null; -- an earlier bot match left before its end pays nothing
  insert into public.rush_bot (user_id, level, bot_level) values (auth.uid(), lv, least(100, lv + 1)) returning * into t;
  return jsonb_build_object('status', 'bot', 'ticket', t.id, 'level', t.level, 'bot_level', t.bot_level);
end $$;

-- the bot match ended: pay the reward and fill the eggs
drop function if exists public.rush_end(uuid, text, int);
create or replace function public.rush_end(p_ticket uuid, p_result text, p_dmg int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t public.rush_bot; p public.profiles; eg jsonb; mn int; mx int; arr int[]; g int := 0; e int := 0;
  share numeric;
begin
  select * into t from public.rush_bot where id = p_ticket and user_id = auth.uid() for update;
  if not found then raise exception 'no_ticket'; end if;
  if t.ended_at is not null then raise exception 'already_ended'; end if;
  if p_result is null or p_result not in ('win', 'loss', 'draw') then raise exception 'bad_result'; end if;
  if t.created_at < now() - interval '2 hours' then raise exception 'expired'; end if;
  -- a result sent straight away (no match played) pays nothing; with strong gear one shot can end a real match,
  -- so this only stops a result sent within 10 s of the bot match being handed out (Karoz 2026-10-15)
  if t.created_at > now() - interval '10 seconds' then raise exception 'too_fast'; end if;
  -- a winner gets it all, a loss or a draw 25%; no damage dealt, nothing (Karoz 2026-10-15)
  share := case when coalesce(p_dmg, 0) <= 0 then 0 when p_result = 'win' then 1 else 0.25 end;
  g := round(10 * t.level * share); -- 100 x level / 10
  e := round(20 * t.level * share); -- 200 x level / 10
  if share > 0 then
    -- this mode's range; before per-mode ranges the setting was one { min, max } for this mode
    select coalesce(value->'rush_bot', case when value ? 'min' then value end) into eg from public.game_settings where key = 'egg';
    if eg is not null and jsonb_typeof(eg->'min') = 'number' and jsonb_typeof(eg->'max') = 'number' then
      mn := greatest(0, (eg->>'min')::numeric::int); mx := greatest(mn, (eg->>'max')::numeric::int);
      if mx > 0 then arr := array(select mn + floor(random() * (mx - mn + 1))::int from generate_series(1, 12)); end if;
    end if;
  end if;
  if g > 0 then update public.profiles set gold = gold + g where id = auth.uid(); end if;
  if e > 0 then perform public.gain_exp(auth.uid(), e, 'rush_bot'); end if;
  update public.rush_bot set result = p_result, ended_at = now(), gold = g, exp = e, eggs = arr where id = t.id;
  select * into p from public.profiles where id = auth.uid();
  return jsonb_build_object('result', p_result, 'level', t.level, 'dmg', greatest(0, coalesce(p_dmg, 0)), 'gold', g, 'exp', e, 'eggs', coalesce(array_length(arr, 1), 0),
    'me', jsonb_build_object('level', p.level, 'exp', p.exp, 'gold', p.gold, 'gem', p.gem, 'coupon', p.coupon));
end $$;

-- break one of the 12 eggs (0-11): its coupons go to the player, and all 12 are shown
create or replace function public.egg_pick(p_ticket uuid, p_index int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.rush_bot; n int; p public.profiles;
begin
  select * into t from public.rush_bot where id = p_ticket and user_id = auth.uid() for update;
  if not found then raise exception 'no_ticket'; end if;
  if t.eggs is null then raise exception 'no_eggs'; end if;
  if t.egg_pick is not null then raise exception 'already_picked'; end if;
  if p_index is null or p_index < 0 or p_index >= array_length(t.eggs, 1) then raise exception 'bad_egg'; end if;
  n := t.eggs[p_index + 1];
  update public.rush_bot set egg_pick = p_index where id = t.id;
  update public.profiles set coupon = coupon + n where id = auth.uid() returning * into p;
  return jsonb_build_object('pick', p_index, 'won', n, 'eggs', to_jsonb(t.eggs), 'coupon', p.coupon);
end $$;

revoke all on function public.gain_exp(uuid, int, text) from public, anon, authenticated;
revoke all on function public.match_bot(), public.rush_end(uuid, text, int), public.egg_pick(uuid, int) from public;
grant execute on function public.match_bot(), public.rush_end(uuid, text, int), public.egg_pick(uuid, int) to authenticated;
