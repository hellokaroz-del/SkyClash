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
-- Egg prizes (Karoz 2026-10-16): once the admin panel has set a prize list for ลุย against the bot (game_settings
-- egg_pool, see supabase-admin.sql), each egg holds one prize from it (gold, coupons or an item) instead of coupons
-- only. egg_fill and egg_give here are shared with the dungeon's eggs (supabase-dungeon.sql).
-- Run after supabase-items.sql too (prizes that are items go into player_items).

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
alter table public.rush_bot add column if not exists prizes jsonb; -- the 12 eggs when they hold prizes from egg_pool
-- ลุย against a player gets a ticket too (Karoz 2026-10-16: eggs set for "ลุย · เจอผู้เล่น" never showed up):
-- mode 'pvp', with the game code the pair was given. A player match pays like the bot match (Karoz 2026-10-16: the same
-- gold and EXP formula), and its eggs come from the 'rush' prize list
alter table public.rush_bot add column if not exists mode text not null default 'bot';
alter table public.rush_bot add column if not exists game_code text;
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

-- 12 eggs from a prize list in game_settings egg_pool (p_key: 'rush_bot', 'dg:slime:normal' ...): each egg one prize
-- picked by its chance weight, with an amount between its min and max. Null when that list is not set or is empty.
create or replace function public.egg_fill(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pool jsonb; tot numeric; r numeric; x jsonb; out jsonb := '[]'::jsonb; i int; n int;
begin
  select value->p_key into pool from public.game_settings where key = 'egg_pool';
  if pool is null or jsonb_typeof(pool) <> 'array' or jsonb_array_length(pool) = 0 then return null; end if;
  select sum((e->>'w')::numeric) into tot from jsonb_array_elements(pool) e;
  if coalesce(tot, 0) <= 0 then return null; end if;
  for i in 1..12 loop
    r := random() * tot;
    for x in select e from jsonb_array_elements(pool) e loop
      r := r - (x->>'w')::numeric;
      exit when r < 0;
    end loop;
    n := (x->>'min')::int + floor(random() * ((x->>'max')::int - (x->>'min')::int + 1))::int;
    out := out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('t', x->>'t', 'n', n, 'id', x->>'id', 'slot', nullif(x->>'slot', ''),
      'stats', case when x->>'t' = 'item' then coalesce(x->'stats', '{}'::jsonb) end, 'bound', case when x->>'t' = 'item' then coalesce((x->>'bound')::boolean, true) end)));
  end loop;
  return out;
end $$;
-- hand one prize to a player: gold and coupons onto the profile; an item into the bag. Items with no slot and no stats
-- (materials) stack onto a pile of the same kind; gear comes one piece per row
create or replace function public.egg_give(p_id uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare n int := greatest(1, coalesce((p->>'n')::int, 1)); k int; pile bigint;
begin
  if p->>'t' = 'gold' then update public.profiles set gold = gold + n where id = p_id;
  elsif p->>'t' = 'coupon' then update public.profiles set coupon = coupon + n where id = p_id;
  elsif p->>'t' = 'item' then
    if p->>'slot' is null and coalesce(p->'stats', '{}'::jsonb) = '{}'::jsonb then
      select id into pile from public.player_items where owner = p_id and item_id = p->>'id' and mail_id is null and expires_at is null
        and bound = coalesce((p->>'bound')::boolean, true) and stats = '{}'::jsonb and slot is null and qty + n <= 9999 limit 1 for update;
      if pile is not null then update public.player_items set qty = qty + n where id = pile; return; end if;
      insert into public.player_items (owner, item_id, qty, bound, stats) values (p_id, p->>'id', n, coalesce((p->>'bound')::boolean, true), '{}'::jsonb);
    else
      for k in 1..least(n, 50) loop
        insert into public.player_items (owner, item_id, slot, qty, bound, stats)
        values (p_id, p->>'id', p->>'slot', 1, coalesce((p->>'bound')::boolean, true), coalesce(p->'stats', '{}'::jsonb));
      end loop;
    end if;
  end if;
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

-- ลุย found a player: a ticket for that match, asked by each side as its game opens. Only while the pairing is fresh
-- (the queue row still holds this game code, made in the last 2 minutes); asking again for the same game gives the same ticket
create or replace function public.match_ticket(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q public.match_queue; lv int; plv int; t public.rush_bot;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into t from public.rush_bot where user_id = auth.uid() and mode = 'pvp' and game_code = p_code and ended_at is null
    and created_at > now() - interval '2 hours' order by created_at desc limit 1;
  if found then return jsonb_build_object('ticket', t.id); end if;
  select * into q from public.match_queue where user_id = auth.uid();
  if not found or q.game_code is null or q.game_code <> p_code or q.matched_at < now() - interval '2 minutes' then raise exception 'no_match'; end if;
  select greatest(1, least(100, coalesce(level, 1))) into lv from public.profiles where id = auth.uid();
  select greatest(1, least(100, coalesce(level, 1))) into plv from public.profiles where id = q.partner;
  delete from public.rush_bot where user_id = auth.uid() and ended_at is null; -- an earlier ลุย match left before its end pays nothing
  insert into public.rush_bot (user_id, level, bot_level, mode, game_code) values (auth.uid(), lv, coalesce(plv, lv), 'pvp', p_code) returning * into t;
  return jsonb_build_object('ticket', t.id);
end $$;

-- the bot match ended: pay the reward and fill the eggs
drop function if exists public.rush_end(uuid, text, int);
create or replace function public.rush_end(p_ticket uuid, p_result text, p_dmg int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t public.rush_bot; p public.profiles; eg jsonb; mn int; mx int; arr int[]; g int := 0; e int := 0;
  share numeric; pz jsonb;
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
  if share > 0 then pz := public.egg_fill(case when t.mode = 'pvp' then 'rush' else 'rush_bot' end); end if;
  if share > 0 and pz is null then
    -- this mode's range; before per-mode ranges the setting was one { min, max } for the bot mode
    select case when t.mode = 'pvp' then value->'rush' else coalesce(value->'rush_bot', case when value ? 'min' then value end) end into eg from public.game_settings where key = 'egg';
    if eg is not null and jsonb_typeof(eg->'min') = 'number' and jsonb_typeof(eg->'max') = 'number' then
      mn := greatest(0, (eg->>'min')::numeric::int); mx := greatest(mn, (eg->>'max')::numeric::int);
      if mx > 0 then arr := array(select mn + floor(random() * (mx - mn + 1))::int from generate_series(1, 12)); end if;
    end if;
  end if;
  if g > 0 then update public.profiles set gold = gold + g where id = auth.uid(); end if;
  if e > 0 then perform public.gain_exp(auth.uid(), e, case when t.mode = 'pvp' then 'rush_pvp' else 'rush_bot' end); end if;
  update public.rush_bot set result = p_result, ended_at = now(), gold = g, exp = e, eggs = arr, prizes = pz where id = t.id;
  select * into p from public.profiles where id = auth.uid();
  return jsonb_build_object('result', p_result, 'mode', t.mode, 'level', t.level, 'dmg', greatest(0, coalesce(p_dmg, 0)), 'gold', g, 'exp', e, 'eggs', coalesce(jsonb_array_length(pz), array_length(arr, 1), 0),
    'me', jsonb_build_object('level', p.level, 'exp', p.exp, 'gold', p.gold, 'gem', p.gem, 'coupon', p.coupon));
end $$;

-- break one of the 12 eggs (0-11): its coupons (or prize) go to the player, and all 12 are shown
create or replace function public.egg_pick(p_ticket uuid, p_index int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t public.rush_bot; n int; p public.profiles;
begin
  select * into t from public.rush_bot where id = p_ticket and user_id = auth.uid() for update;
  if not found then raise exception 'no_ticket'; end if;
  if t.eggs is null and t.prizes is null then raise exception 'no_eggs'; end if;
  if t.egg_pick is not null then raise exception 'already_picked'; end if;
  if t.prizes is not null then
    if p_index is null or p_index < 0 or p_index >= jsonb_array_length(t.prizes) then raise exception 'bad_egg'; end if;
    update public.rush_bot set egg_pick = p_index where id = t.id;
    perform public.egg_give(auth.uid(), t.prizes->p_index);
    select * into p from public.profiles where id = auth.uid();
    return jsonb_build_object('pick', p_index, 'won', t.prizes->p_index, 'eggs', t.prizes, 'coupon', p.coupon, 'gold', p.gold);
  end if;
  if p_index is null or p_index < 0 or p_index >= array_length(t.eggs, 1) then raise exception 'bad_egg'; end if;
  n := t.eggs[p_index + 1];
  update public.rush_bot set egg_pick = p_index where id = t.id;
  update public.profiles set coupon = coupon + n where id = auth.uid() returning * into p;
  return jsonb_build_object('pick', p_index, 'won', n, 'eggs', to_jsonb(t.eggs), 'coupon', p.coupon);
end $$;

revoke all on function public.gain_exp(uuid, int, text) from public, anon, authenticated;
revoke all on function public.egg_fill(text), public.egg_give(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.match_bot(), public.match_ticket(text), public.rush_end(uuid, text, int), public.egg_pick(uuid, int) from public;
grant execute on function public.match_bot(), public.match_ticket(text), public.rush_end(uuid, text, int), public.egg_pick(uuid, int) to authenticated;
