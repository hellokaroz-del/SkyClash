-- Ages of Aether lobby: items players own, mail, and the admin tool that creates items (Karoz 2026-10-08)
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Safe to run more than once. Run after supabase-chat-channels.sql (it needs profiles.is_admin).
--
-- Item kinds (names, pictures, default stats) live in the game's item list (ITEMS in lobby/index.html); a row here says
-- who owns how many of which kind, with its own stats, whether it is personal, and when it runs out.
-- Players can only read their own rows. Every change goes through the functions below, which check who is asking.

-- 1) mail: a letter to one player, kept 30 days; items attached to it wait in player_items with mail_id set
create table if not exists public.mails (
  id bigint generated always as identity primary key,
  to_user uuid not null references public.profiles (id) on delete cascade,
  from_name text not null default 'GM',
  subject text not null default '' check (char_length(subject) <= 60),
  body text not null default '' check (char_length(body) <= 500),
  read_at timestamptz,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);
create index if not exists mails_to_idx on public.mails (to_user, created_at desc);
alter table public.mails enable row level security;
revoke all on public.mails from anon, authenticated;
grant select on public.mails to authenticated;
drop policy if exists "read own mail" on public.mails;
create policy "read own mail" on public.mails for select to authenticated using (to_user = auth.uid());

-- 2) items: in the bag when mail_id is null, attached to a letter otherwise
--    bound: true = ส่วนตัว (stays with this character), false = สาธารณะ (may be traded once trading exists)
--    expires_at: null = ถาวร
create table if not exists public.player_items (
  id bigint generated always as identity primary key,
  owner uuid not null references public.profiles (id) on delete cascade,
  item_id text not null check (char_length(item_id) between 1 and 40),
  slot text,
  qty int not null default 1 check (qty between 1 and 9999),
  bound boolean not null default true,
  stats jsonb not null default '{}'::jsonb,
  expires_at timestamptz,
  equipped boolean not null default false,
  mail_id bigint references public.mails (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists player_items_owner_idx on public.player_items (owner);
alter table public.player_items enable row level security;
revoke all on public.player_items from anon, authenticated;
grant select on public.player_items to authenticated;
drop policy if exists "read own items" on public.player_items;
create policy "read own items" on public.player_items for select to authenticated using (owner = auth.uid());

-- 3) admin: create an item for players, into their bag or by mail
--    p_names: in-game names; p_ids: player ids (the town sends everyone online this way); p_days null = ถาวร
create or replace function public.admin_give_item(
  p_names text[], p_ids uuid[], p_item text, p_slot text, p_qty int, p_bound boolean, p_stats jsonb, p_days int,
  p_via text, p_subject text, p_body text
) returns int
language plpgsql security definer set search_path = public as $$
declare me public.profiles; t record; n int := 0; mid bigint; exp timestamptz;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or not me.is_admin then raise exception 'not_admin'; end if;
  if p_item is null or char_length(p_item) = 0 then raise exception 'no_item'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 9999 then raise exception 'bad_qty'; end if;
  if p_days is not null and (p_days < 1 or p_days > 3650) then raise exception 'bad_days'; end if;
  if p_via not in ('bag', 'mail') then raise exception 'bad_via'; end if;
  exp := case when p_days is null then null else now() + make_interval(days => p_days) end;
  for t in
    select distinct id from public.profiles
    where lower(name) = any (select lower(btrim(x)) from unnest(coalesce(p_names, '{}')) x where btrim(x) <> '')
       or id = any (coalesce(p_ids, '{}'))
  loop
    mid := null;
    if p_via = 'mail' then
      insert into public.mails (to_user, from_name, subject, body)
      values (t.id, me.name, left(coalesce(nullif(btrim(p_subject), ''), 'ของขวัญจาก GM'), 60), left(coalesce(p_body, ''), 500))
      returning id into mid;
    end if;
    insert into public.player_items (owner, item_id, slot, qty, bound, stats, expires_at, mail_id)
    values (t.id, p_item, p_slot, p_qty, coalesce(p_bound, true), coalesce(p_stats, '{}'::jsonb), exp, mid);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'no_target'; end if;
  return n;
end $$;
revoke all on function public.admin_give_item(text[], uuid[], text, text, int, boolean, jsonb, int, text, text, text) from public;
grant execute on function public.admin_give_item(text[], uuid[], text, text, int, boolean, jsonb, int, text, text, text) to authenticated;

-- 4) wear / take off: one item per slot
create or replace function public.equip_item(p_id bigint, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare it public.player_items;
begin
  select * into it from public.player_items where id = p_id and owner = auth.uid() and mail_id is null for update;
  if not found then raise exception 'no_item'; end if;
  if it.expires_at is not null and it.expires_at < now() then raise exception 'expired'; end if;
  if p_on then
    update public.player_items set equipped = false where owner = auth.uid() and slot = it.slot and id <> p_id;
  end if;
  update public.player_items set equipped = p_on where id = p_id;
end $$;
revoke all on function public.equip_item(bigint, boolean) from public;
grant execute on function public.equip_item(bigint, boolean) to authenticated;

-- 5) mail: mark read, take the items into the bag (one letter, or all when p_mail is null), delete letters
create or replace function public.read_mail(p_mail bigint) returns void
language sql security definer set search_path = public as $$
  update public.mails set read_at = coalesce(read_at, now()) where id = p_mail and to_user = auth.uid();
$$;
create or replace function public.claim_mail(p_mail bigint) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.player_items i set mail_id = null
  from public.mails m
  where i.mail_id = m.id and m.to_user = auth.uid() and m.expires_at > now() and (p_mail is null or m.id = p_mail);
  get diagnostics n = row_count;
  update public.mails set read_at = coalesce(read_at, now()) where to_user = auth.uid() and (p_mail is null or id = p_mail);
  return n;
end $$;
-- deleting a letter also deletes items still attached to it
create or replace function public.delete_mail(p_ids bigint[]) returns void
language sql security definer set search_path = public as $$
  delete from public.mails where to_user = auth.uid() and id = any (p_ids);
$$;
-- run each time the bag or mail is opened: drop what has run out
create or replace function public.tidy_items() returns void
language sql security definer set search_path = public as $$
  delete from public.player_items where owner = auth.uid() and expires_at is not null and expires_at < now();
  delete from public.mails where to_user = auth.uid() and expires_at < now();
$$;
revoke all on function public.read_mail(bigint), public.claim_mail(bigint), public.delete_mail(bigint[]), public.tidy_items() from public;
grant execute on function public.read_mail(bigint), public.claim_mail(bigint), public.delete_mail(bigint[]), public.tidy_items() to authenticated;

-- 6) destroy an item from the bag (Karoz 2026-10-08: dragging an item out of the bag, after a warning)
create or replace function public.destroy_item(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.player_items where id = p_id and owner = auth.uid() and mail_id is null;
  if not found then raise exception 'no_item'; end if;
end $$;
revoke all on function public.destroy_item(bigint) from public;
grant execute on function public.destroy_item(bigint) to authenticated;
