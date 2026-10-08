-- Ages of Aether lobby: ลุย matchmaking on the server (Karoz 2026-10-09)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run more than once.
--
-- One row per player looking for a match. The server pairs the two oldest waiting players of the same team size under a
-- lock, so exactly one pair is made, both sides get the same game code, and one of them is told to host it. The town
-- calls match_join when ลุย is pressed, match_poll every second while waiting (that also keeps the row alive), and
-- match_leave on cancel. A row not polled for 15 s is treated as gone and removed.

create table if not exists public.match_queue (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  room text not null default '',
  size int not null default 1 check (size between 1 and 4),
  created_at timestamptz not null default now(),
  seen_at timestamptz not null default now(),
  partner uuid,
  partner_room text,
  game_code text,
  role text check (role in ('host', 'guest')),
  matched_at timestamptz
);
alter table public.match_queue enable row level security;
revoke all on public.match_queue from anon, authenticated;
-- no direct access at all: only the functions below touch it

-- the row this player sees: waiting, or matched (with the game code and whether to host it)
create or replace function public.match_view(q public.match_queue) returns jsonb
language sql immutable as $$
  select jsonb_build_object('status', case when q.game_code is null then 'waiting' else 'matched' end,
    'game_code', q.game_code, 'role', q.role, 'partner_room', q.partner_room,
    'partner_name', (select name from public.profiles where id = q.partner));
$$;

create or replace function public.match_pair(me uuid) returns void
language plpgsql security definer set search_path = public as $$
declare q public.match_queue; o public.match_queue; code text;
begin
  -- one pairing at a time across the whole game, so two players are never both given the same opponent
  perform pg_advisory_xact_lock(424242);
  delete from public.match_queue where seen_at < now() - interval '15 seconds';
  delete from public.match_queue where matched_at < now() - interval '2 minutes';
  select * into q from public.match_queue where user_id = me for update;
  if not found or q.game_code is not null then return; end if;
  select * into o from public.match_queue
    where user_id <> me and game_code is null and size = q.size
    order by created_at limit 1 for update;
  if not found then return; end if;
  -- a game code no other fresh match is using
  loop
    code := (1000 + floor(random() * 9000))::int::text;
    exit when not exists (select 1 from public.match_queue where game_code = code);
  end loop;
  -- whoever has waited longer hosts the game
  update public.match_queue set partner = me, partner_room = q.room, game_code = code, role = 'host', matched_at = now() where user_id = o.user_id;
  update public.match_queue set partner = o.user_id, partner_room = o.room, game_code = code, role = 'guest', matched_at = now() where user_id = me;
end $$;

create or replace function public.match_join(p_room text, p_size int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q public.match_queue;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  insert into public.match_queue (user_id, room, size) values (auth.uid(), coalesce(p_room, ''), greatest(1, least(4, coalesce(p_size, 1))))
  on conflict (user_id) do update set room = excluded.room, size = excluded.size, created_at = now(), seen_at = now(),
    partner = null, partner_room = null, game_code = null, role = null, matched_at = null;
  perform public.match_pair(auth.uid());
  select * into q from public.match_queue where user_id = auth.uid();
  return public.match_view(q);
end $$;

create or replace function public.match_poll() returns jsonb
language plpgsql security definer set search_path = public as $$
declare q public.match_queue;
begin
  update public.match_queue set seen_at = now() where user_id = auth.uid() returning * into q;
  if not found then return jsonb_build_object('status', 'none'); end if;
  if q.game_code is null then
    perform public.match_pair(auth.uid());
    select * into q from public.match_queue where user_id = auth.uid();
    if not found then return jsonb_build_object('status', 'none'); end if;
  end if;
  return public.match_view(q);
end $$;

create or replace function public.match_leave() returns void
language sql security definer set search_path = public as $$
  delete from public.match_queue where user_id = auth.uid();
$$;

revoke all on function public.match_pair(uuid) from public, anon, authenticated;
revoke all on function public.match_join(text, int), public.match_poll(), public.match_leave() from public;
grant execute on function public.match_join(text, int), public.match_poll(), public.match_leave() to authenticated;
