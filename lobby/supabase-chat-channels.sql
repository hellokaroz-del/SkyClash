-- SkyClash town lobby: chat channels (world, guild, whisper, room, announce)
-- Run AFTER supabase-setup.sql. Paste the whole file into Supabase > SQL Editor > New query, then Run.
-- Safe to run more than once.

-- 1) Profile fields used by the channels
alter table public.profiles add column if not exists guild text check (guild is null or char_length(guild) between 1 and 16);
alter table public.profiles add column if not exists room text check (room is null or room ~ '^[0-9]{4}$');
alter table public.profiles add column if not exists is_admin boolean not null default false;

-- players may set their own name, guild tag and current room; is_admin, level and exp stay server-side
revoke update on public.profiles from authenticated;
grant update (name, guild, room) on public.profiles to authenticated;

create or replace function public.profiles_touch() returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  new.name := btrim(new.name);
  new.guild := nullif(btrim(coalesce(new.guild, '')), '');
  return new;
end $$;

-- 2) Message fields
alter table public.chat_messages add column if not exists to_id uuid references public.profiles(id) on delete cascade;
alter table public.chat_messages add column if not exists to_name text;
alter table public.chat_messages add column if not exists guild text;
alter table public.chat_messages add column if not exists room text;
alter table public.chat_messages drop constraint if exists chat_messages_channel_check;
alter table public.chat_messages add constraint chat_messages_channel_check
  check (channel in ('world', 'guild', 'whisper', 'room', 'announce'));
create index if not exists chat_messages_to_idx on public.chat_messages (to_id);

revoke insert on public.chat_messages from authenticated;
grant insert (body, channel, to_id) on public.chat_messages to authenticated;

-- 3) Who can read what: world and announce for everyone, guild and room for members,
--    whispers only for the sender and the receiver
create or replace function public.my_profile_field(f text) returns text language sql stable security definer set search_path = public as $$
  select case f when 'guild' then guild when 'room' then room end from public.profiles where id = auth.uid()
$$;
revoke execute on function public.my_profile_field(text) from public, anon;
grant execute on function public.my_profile_field(text) to authenticated;

drop policy if exists "chat readable" on public.chat_messages;
create policy "chat readable" on public.chat_messages for select to authenticated using (
  channel in ('world', 'announce')
  or user_id = auth.uid()
  or (channel = 'whisper' and to_id = auth.uid())
  or (channel = 'guild' and guild = public.my_profile_field('guild'))
  or (channel = 'room' and room = public.my_profile_field('room'))
);

-- 4) The server fills in sender, guild, room and receiver, and checks permissions
create or replace function public.chat_before_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype; tname text;
begin
  new.user_id := auth.uid();
  new.created_at := now();
  new.body := btrim(new.body);
  select * into p from public.profiles where id = new.user_id;
  if not found then raise exception 'no_profile'; end if;
  new.name := p.name;
  new.guild := null; new.room := null; new.to_name := null;
  if new.channel = 'guild' then
    if p.guild is null then raise exception 'no_guild'; end if;
    new.guild := p.guild;
  elsif new.channel = 'room' then
    if p.room is null then raise exception 'no_room'; end if;
    new.room := p.room;
  elsif new.channel = 'whisper' then
    select name into tname from public.profiles where id = new.to_id;
    if tname is null then raise exception 'no_target'; end if;
    new.to_name := tname;
  elsif new.channel = 'announce' then
    if not p.is_admin then raise exception 'not_admin'; end if;
  end if;
  if new.channel <> 'whisper' then new.to_id := null; end if;
  if exists (select 1 from public.chat_messages where user_id = new.user_id and created_at > now() - interval '2 seconds') then
    raise exception 'slow_down';
  end if;
  delete from public.chat_messages where created_at < now() - interval '3 days';
  return new;
end $$;
revoke execute on function public.chat_before_insert() from public, anon, authenticated;

-- 5) Make yourself admin (so you can post announcements):
--    open the town page once with your name set, then run this with your in-game name.
-- update public.profiles set is_admin = true where name = 'GM_Karoz';
