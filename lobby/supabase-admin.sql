-- Ages of Aether lobby: admin tools (Karoz 2026-10-15)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Safe to run more than once. Run after all the other lobby SQL files (setup, chat-channels, character, items, match,
-- progress, jobs).
--
-- What it adds:
--   - player fields only the server can change: money (gold, gem, coupon), bonus skill points, last seen, ban and mute
--   - admin_log: every admin action (who did what to whom, when); only admins can read it
--   - game_settings: maintenance mode and which admin-only jobs are open to everyone
--   - match_results: one row per finished match per player (job, against a bot or a player, win/loss/draw), for the
--     win-rate table. The player's own page reports it, so it shows how jobs do in practice, not anti-cheat proof.
--   - the admin functions the town's admin panel calls; each one checks profiles.is_admin on the server

-- 1) player fields (players can read them, only the functions below change them)
alter table public.profiles add column if not exists gold bigint not null default 0;
alter table public.profiles add column if not exists gem bigint not null default 0;
alter table public.profiles add column if not exists coupon bigint not null default 0;
alter table public.profiles add column if not exists skill_bonus int not null default 0;
alter table public.profiles add column if not exists last_seen timestamptz;
alter table public.profiles add column if not exists banned_until timestamptz;
alter table public.profiles add column if not exists ban_reason text;
alter table public.profiles add column if not exists muted_until timestamptz;
alter table public.profiles add column if not exists mute_reason text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_money_check') then
    alter table public.profiles add constraint profiles_money_check check (gold >= 0 and gem >= 0 and coupon >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_skill_bonus_check') then
    alter table public.profiles add constraint profiles_skill_bonus_check check (skill_bonus between 0 and 200);
  end if;
end $$;

-- skill points = character level (40 at most) + the bonus an admin gives; the same rule as supabase-jobs.sql
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
        if jsonb_typeof(lv) <> 'number' or (lv::text)::numeric not between 0 and 5 or (lv::text)::numeric <> trunc((lv::text)::numeric) then raise exception 'bad_skill_level'; end if;
        spent := spent + (lv::text)::int;
      end loop;
    end if;
    if spent > least(greatest(coalesce(new.level, 1), 1), 40) + coalesce(new.skill_bonus, 0) then raise exception 'not_enough_skill_points'; end if;
  end loop;
  return new;
end $$;

-- 2) admin log
create table if not exists public.admin_log (
  id bigint generated always as identity primary key,
  admin_id uuid references public.profiles (id) on delete set null,
  admin_name text not null default '',
  action text not null,
  target_id uuid,
  target_name text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists admin_log_created_idx on public.admin_log (created_at desc);
alter table public.admin_log enable row level security;
revoke all on public.admin_log from anon, authenticated;
grant select on public.admin_log to authenticated;
drop policy if exists "admins read log" on public.admin_log;
create policy "admins read log" on public.admin_log for select to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and is_admin));

-- the admin calling, or an error for anyone else
create or replace function public.admin_me() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or not me.is_admin then raise exception 'not_admin'; end if;
  return me;
end $$;
revoke all on function public.admin_me() from public, anon, authenticated;

create or replace function public.admin_note(p_action text, p_target uuid, p_detail jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  insert into public.admin_log (admin_id, admin_name, action, target_id, target_name, detail)
  values (auth.uid(), coalesce(me.name, ''), p_action, p_target, (select name from public.profiles where id = p_target), coalesce(p_detail, '{}'::jsonb));
end $$;
revoke all on function public.admin_note(text, uuid, jsonb) from public, anon, authenticated;

-- 3) game settings: maintenance = { "on": true/false, "msg": "..." }, jobs_open = { "doram": true },
--    egg = { "rush_bot": { "min": n, "max": n }, "rush": {...}, "duel": {...}, "dungeon": {...} } (coupons in each egg,
--    one range per mode; only rush_bot hands out eggs so far, supabase-rush.sql)
create table if not exists public.game_settings (
  key text primary key check (key in ('maintenance', 'jobs_open', 'egg')),
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.game_settings enable row level security;
revoke all on public.game_settings from anon, authenticated;
grant select on public.game_settings to anon, authenticated;
drop policy if exists "settings readable" on public.game_settings;
create policy "settings readable" on public.game_settings for select to anon, authenticated using (true);
alter table public.game_settings drop constraint if exists game_settings_key_check;
alter table public.game_settings add constraint game_settings_key_check check (key in ('maintenance', 'jobs_open', 'egg'));
insert into public.game_settings (key, value) values ('maintenance', '{"on": false, "msg": ""}'), ('jobs_open', '{}') on conflict (key) do nothing;

create or replace function public.maintenance_on() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (value->>'on')::boolean from public.game_settings where key = 'maintenance'), false)
$$;
revoke all on function public.maintenance_on() from public, anon, authenticated;

-- 4) bans, mutes and maintenance are enforced by the server, not only hidden on the page:
--    a banned or muted player cannot chat, a banned player (or anyone but an admin during maintenance) cannot queue for ลุย
create or replace function public.chat_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if found and not p.is_admin then
    if p.banned_until is not null and p.banned_until > now() then raise exception 'banned'; end if;
    if p.muted_until is not null and p.muted_until > now() then raise exception 'muted'; end if;
    if public.maintenance_on() then raise exception 'maintenance'; end if;
  end if;
  return new;
end $$;
revoke execute on function public.chat_guard() from public, anon, authenticated;
drop trigger if exists chat_guard on public.chat_messages;
create trigger chat_guard before insert on public.chat_messages for each row execute function public.chat_guard();

create or replace function public.match_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if found and not p.is_admin then
    if p.banned_until is not null and p.banned_until > now() then raise exception 'banned'; end if;
    if public.maintenance_on() then raise exception 'maintenance'; end if;
  end if;
  return new;
end $$;
revoke execute on function public.match_guard() from public, anon, authenticated;
drop trigger if exists match_guard on public.match_queue;
create trigger match_guard before insert on public.match_queue for each row execute function public.match_guard();

-- 5) last seen: the town calls this when it opens and every few minutes after
create or replace function public.touch_seen() returns void
language sql security definer set search_path = public as $$
  update public.profiles set last_seen = now() where id = auth.uid();
$$;
revoke all on function public.touch_seen() from public;
grant execute on function public.touch_seen() to authenticated;

-- 6) match results (reported by each player's own page at the end of a match; at most one per 20 seconds)
create table if not exists public.match_results (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  job text not null,
  vs text not null check (vs in ('bot', 'pvp')),
  result text not null check (result in ('win', 'loss', 'draw')),
  created_at timestamptz not null default now()
);
create index if not exists match_results_created_idx on public.match_results (created_at desc);
alter table public.match_results enable row level security;
revoke all on public.match_results from anon, authenticated;

create or replace function public.record_match(p_vs text, p_result text) returns void
language plpgsql security definer set search_path = public as $$
declare j text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select job into j from public.profiles where id = auth.uid();
  if j is null then return; end if;
  if exists (select 1 from public.match_results where user_id = auth.uid() and created_at > now() - interval '20 seconds') then return; end if;
  insert into public.match_results (user_id, job, vs, result) values (auth.uid(), j, p_vs, p_result);
end $$;
revoke all on function public.record_match(text, text) from public;
grant execute on function public.record_match(text, text) to authenticated;

-- 7) EXP needed to go from level lv to lv + 1. The same curve as the town page (expNeed in lobby/index.html):
--    level 1 -> 2 is 1,000 (exp-table-v3); the rest is the placeholder curve until Karoz's full table is in
create or replace function public.exp_need(lv int) returns int language sql immutable as $$
  select case when lv <= 1 then 1000 else (round(1000 * power(1.15, lv - 1) / 10) * 10)::int end
$$;

-- ---------- admin functions ----------

-- a player's items, mail included (players can only read their own)
create or replace function public.admin_player_items(p_id uuid) returns setof public.player_items
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_me();
  return query select * from public.player_items where owner = p_id order by created_at desc;
end $$;

-- a player's recent chat (world, guild, room, announce; whispers stay private)
create or replace function public.admin_player_chat(p_id uuid, p_limit int) returns setof public.chat_messages
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_me();
  return query select * from public.chat_messages where user_id = p_id and channel <> 'whisper'
    order by created_at desc limit least(greatest(coalesce(p_limit, 30), 1), 200);
end $$;

-- add or take away EXP; levels go up or down with it (level 1 to 100, EXP never below 0)
create or replace function public.admin_add_exp(p_id uuid, p_delta int, p_reason text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare p public.profiles; lv int; ex bigint; old_lv int; old_ex int;
begin
  perform public.admin_me();
  if p_delta is null or p_delta = 0 or abs(p_delta) > 100000000 then raise exception 'bad_amount'; end if;
  select * into p from public.profiles where id = p_id for update;
  if not found then raise exception 'no_target'; end if;
  old_lv := greatest(coalesce(p.level, 1), 1); old_ex := greatest(coalesce(p.exp, 0), 0);
  lv := old_lv; ex := old_ex + p_delta;
  while ex >= public.exp_need(lv) and lv < 100 loop ex := ex - public.exp_need(lv); lv := lv + 1; end loop;
  if lv >= 100 then lv := 100; ex := least(ex, public.exp_need(100) - 1); end if;
  while ex < 0 and lv > 1 loop lv := lv - 1; ex := ex + public.exp_need(lv); end loop;
  if ex < 0 then ex := 0; end if;
  update public.profiles set level = lv, exp = ex::int where id = p_id returning * into p;
  insert into public.exp_log (user_id, source, exp, level_after, exp_after) values (p_id, 'admin', p_delta, p.level, p.exp);
  perform public.admin_note('exp', p_id, jsonb_build_object('delta', p_delta, 'from', jsonb_build_object('level', old_lv, 'exp', old_ex),
    'to', jsonb_build_object('level', p.level, 'exp', p.exp), 'reason', coalesce(p_reason, '')));
  return p;
end $$;

-- set level, EXP, money and bonus skill points to exact values (null = leave as it is)
create or replace function public.admin_set_player(p_id uuid, p_level int, p_exp int, p_gold bigint, p_gem bigint, p_coupon bigint,
  p_skill_bonus int, p_reason text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare p public.profiles; o public.profiles;
begin
  perform public.admin_me();
  if p_level is not null and (p_level < 1 or p_level > 100) then raise exception 'bad_level'; end if;
  if p_exp is not null and p_exp < 0 then raise exception 'bad_amount'; end if;
  if coalesce(p_gold, 0) < 0 or coalesce(p_gem, 0) < 0 or coalesce(p_coupon, 0) < 0 then raise exception 'bad_amount'; end if;
  if p_skill_bonus is not null and (p_skill_bonus < 0 or p_skill_bonus > 200) then raise exception 'bad_amount'; end if;
  select * into o from public.profiles where id = p_id for update;
  if not found then raise exception 'no_target'; end if;
  update public.profiles set level = coalesce(p_level, level), exp = coalesce(p_exp, exp), gold = coalesce(p_gold, gold),
    gem = coalesce(p_gem, gem), coupon = coalesce(p_coupon, coupon), skill_bonus = coalesce(p_skill_bonus, skill_bonus)
  where id = p_id returning * into p;
  if p.level <> o.level or p.exp <> o.exp then
    insert into public.exp_log (user_id, source, exp, level_after, exp_after) values (p_id, 'admin_set', 0, p.level, p.exp);
  end if;
  perform public.admin_note('set', p_id, jsonb_build_object(
    'from', jsonb_build_object('level', o.level, 'exp', o.exp, 'gold', o.gold, 'gem', o.gem, 'coupon', o.coupon, 'skill_bonus', o.skill_bonus),
    'to', jsonb_build_object('level', p.level, 'exp', p.exp, 'gold', p.gold, 'gem', p.gem, 'coupon', p.coupon, 'skill_bonus', p.skill_bonus),
    'reason', coalesce(p_reason, '')));
  return p;
end $$;

-- free skill reset: one job's levels and loadout, or every job when p_job is null
create or replace function public.admin_reset_skills(p_id uuid, p_job text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_me();
  update public.profiles set skills = case when p_job is null then '{}'::jsonb else coalesce(skills, '{}'::jsonb) - p_job end where id = p_id;
  if not found then raise exception 'no_target'; end if;
  perform public.admin_note('reset_skills', p_id, jsonb_build_object('job', coalesce(p_job, 'all'), 'reason', coalesce(p_reason, '')));
end $$;

-- change a player's job (the player can't: profiles_job_lock). Skills are kept per job, so each job's points stay as they were.
create or replace function public.profiles_job_lock() returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and old.job is not null and new.job is distinct from old.job and current_user in ('anon', 'authenticated') then
    raise exception 'job_locked';
  end if;
  return new;
end $$;

create or replace function public.admin_set_job(p_id uuid, p_job text, p_reason text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare was text; p public.profiles;
begin
  perform public.admin_me();
  if p_job is null or p_job not in ('blade', 'mage', 'archer', 'cleric', 'thief', 'merchant', 'doram') then raise exception 'bad_job'; end if;
  select job into was from public.profiles where id = p_id;
  if not found then raise exception 'no_target'; end if;
  update public.profiles set job = p_job where id = p_id returning * into p;
  perform public.admin_note('job', p_id, jsonb_build_object('from', was, 'to', p_job, 'reason', coalesce(p_reason, '')));
  return p;
end $$;

-- ban or mute: p_minutes > 0 for a while, null for good, 0 to lift it
create or replace function public.admin_ban(p_id uuid, p_kind text, p_minutes int, p_reason text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare p public.profiles; until timestamptz;
begin
  perform public.admin_me();
  if p_kind not in ('ban', 'mute') then raise exception 'bad_kind'; end if;
  if p_id = auth.uid() then raise exception 'not_self'; end if;
  if exists (select 1 from public.profiles where id = p_id and is_admin) then raise exception 'target_admin'; end if;
  if p_minutes is not null and (p_minutes < 0 or p_minutes > 5256000) then raise exception 'bad_amount'; end if;
  until := case when p_minutes is null then 'infinity'::timestamptz when p_minutes = 0 then null else now() + make_interval(mins => p_minutes) end;
  if p_kind = 'ban' then
    update public.profiles set banned_until = until, ban_reason = case when until is null then null else left(coalesce(p_reason, ''), 200) end where id = p_id returning * into p;
    if not found then raise exception 'no_target'; end if;
    -- a banned player leaves the ลุย queue at once
    if until is not null then delete from public.match_queue where user_id = p_id; end if;
  else
    update public.profiles set muted_until = until, mute_reason = case when until is null then null else left(coalesce(p_reason, ''), 200) end where id = p_id returning * into p;
    if not found then raise exception 'no_target'; end if;
  end if;
  perform public.admin_note(case when until is null then 'un' || p_kind else p_kind end, p_id,
    jsonb_build_object('minutes', p_minutes, 'until', until, 'reason', coalesce(p_reason, '')));
  return p;
end $$;

-- delete chat messages (kept in the log with what they said)
create or replace function public.admin_delete_chat(p_ids bigint[]) returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  perform public.admin_me();
  for r in delete from public.chat_messages where id = any (coalesce(p_ids, '{}')) returning * loop
    perform public.admin_note('delete_chat', r.user_id, jsonb_build_object('channel', r.channel, 'body', r.body, 'sent', r.created_at));
    n := n + 1;
  end loop;
  return n;
end $$;

-- money to players: p_all = everyone in the game, else p_ids. Amounts may be negative (never below 0).
create or replace function public.admin_give_money(p_ids uuid[], p_all boolean, p_gold bigint, p_gem bigint, p_coupon bigint, p_reason text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.admin_me();
  if coalesce(p_gold, 0) = 0 and coalesce(p_gem, 0) = 0 and coalesce(p_coupon, 0) = 0 then raise exception 'bad_amount'; end if;
  update public.profiles set gold = greatest(0, gold + coalesce(p_gold, 0)), gem = greatest(0, gem + coalesce(p_gem, 0)),
    coupon = greatest(0, coupon + coalesce(p_coupon, 0))
  where coalesce(p_all, false) or id = any (coalesce(p_ids, '{}'));
  get diagnostics n = row_count;
  if n = 0 then raise exception 'no_target'; end if;
  perform public.admin_note('money', case when n = 1 and not coalesce(p_all, false) then p_ids[1] end,
    jsonb_build_object('players', case when coalesce(p_all, false) then to_jsonb('all'::text) else to_jsonb(n) end, 'gold', coalesce(p_gold, 0),
      'gem', coalesce(p_gem, 0), 'coupon', coalesce(p_coupon, 0), 'reason', coalesce(p_reason, '')));
  return n;
end $$;

-- an item for every player in the game (same fields as admin_give_item in supabase-items.sql)
create or replace function public.admin_give_item_all(p_item text, p_slot text, p_qty int, p_bound boolean, p_stats jsonb, p_days int,
  p_via text, p_subject text, p_body text, p_min_level int) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_me();
  -- admin_give_item writes the admin log itself
  return public.admin_give_item(null, (select coalesce(array_agg(id), '{}') from public.profiles), p_item, p_slot, p_qty, p_bound, p_stats,
    p_days, p_via, p_subject, p_body, p_min_level);
end $$;

-- maintenance and job switches
create or replace function public.admin_set_setting(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare k text; r jsonb;
begin
  perform public.admin_me();
  if p_key not in ('maintenance', 'jobs_open', 'egg') or p_value is null or jsonb_typeof(p_value) <> 'object' then raise exception 'bad_setting'; end if;
  -- egg coupons, one range per mode: whole numbers, 0 <= min <= max <= 1,000,000
  if p_key = 'egg' then
    for k, r in select * from jsonb_each(p_value) loop
      if k not in ('rush_bot', 'rush', 'duel', 'dungeon') or jsonb_typeof(r) <> 'object'
        or not (jsonb_typeof(r->'min') = 'number' and jsonb_typeof(r->'max') = 'number'
        and (r->>'min')::numeric = floor((r->>'min')::numeric) and (r->>'max')::numeric = floor((r->>'max')::numeric)
        and (r->>'min')::numeric >= 0 and (r->>'max')::numeric >= (r->>'min')::numeric and (r->>'max')::numeric <= 1000000) then
        raise exception 'bad_setting';
      end if;
    end loop;
  end if;
  insert into public.game_settings (key, value, updated_at) values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  perform public.admin_note('setting', null, jsonb_build_object('key', p_key, 'value', p_value));
end $$;

-- the overview numbers: players, new today, banned, matches today
create or replace function public.admin_overview() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_me();
  return jsonb_build_object(
    'players', (select count(*) from public.profiles),
    'new_today', (select count(*) from public.profiles where created_at >= date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok'),
    'seen_today', (select count(*) from public.profiles where last_seen >= date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok'),
    'banned', (select count(*) from public.profiles where banned_until > now()),
    'muted', (select count(*) from public.profiles where muted_until > now()),
    'matches_today', (select count(*) from public.match_results where created_at >= date_trunc('day', now() at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok'));
end $$;

-- win rate per job over the last p_days days
create or replace function public.admin_job_stats(p_days int) returns table (job text, vs text, games bigint, wins bigint, losses bigint, draws bigint)
language plpgsql security definer set search_path = public as $$
begin
  perform public.admin_me();
  return query select m.job, m.vs, count(*), count(*) filter (where m.result = 'win'), count(*) filter (where m.result = 'loss'),
    count(*) filter (where m.result = 'draw')
  from public.match_results m where m.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 3650)))
  group by m.job, m.vs order by m.job, m.vs;
end $$;

revoke all on function public.admin_player_items(uuid), public.admin_player_chat(uuid, int), public.admin_add_exp(uuid, int, text),
  public.admin_set_player(uuid, int, int, bigint, bigint, bigint, int, text), public.admin_reset_skills(uuid, text, text), public.admin_set_job(uuid, text, text),
  public.admin_ban(uuid, text, int, text), public.admin_delete_chat(bigint[]), public.admin_give_money(uuid[], boolean, bigint, bigint, bigint, text),
  public.admin_give_item_all(text, text, int, boolean, jsonb, int, text, text, text, int), public.admin_set_setting(text, jsonb),
  public.admin_overview(), public.admin_job_stats(int) from public;
grant execute on function public.admin_player_items(uuid), public.admin_player_chat(uuid, int), public.admin_add_exp(uuid, int, text),
  public.admin_set_player(uuid, int, int, bigint, bigint, bigint, int, text), public.admin_reset_skills(uuid, text, text), public.admin_set_job(uuid, text, text),
  public.admin_ban(uuid, text, int, text), public.admin_delete_chat(bigint[]), public.admin_give_money(uuid[], boolean, bigint, bigint, bigint, text),
  public.admin_give_item_all(text, text, int, boolean, jsonb, int, text, text, text, int), public.admin_set_setting(text, jsonb),
  public.admin_overview(), public.admin_job_stats(int) to authenticated;

