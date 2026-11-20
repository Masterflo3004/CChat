-- Public media library (GIFs, skin images, fonts), community gallery, reports and
-- hash-based moderation.
--
-- Every public file is uploaded through the `upload-media` Edge Function. It
-- computes the SHA-256 on the server, rejects banned hashes and records the file
-- in media_assets. Clients can no longer write to the public buckets directly.
-- Moderators ban a file's hash through the `moderate` Edge Function: every copy
-- is deleted and identical uploads are refused from then on.

-------------------------------------------------------------------------------
-- Moderators
-------------------------------------------------------------------------------

create table public.moderators (
  user_id     uuid primary key references public.profiles on delete cascade,
  created_at  timestamptz not null default now()
);
alter table public.moderators enable row level security;

create function public.is_moderator()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (select 1 from public.moderators where user_id = (select auth.uid()));
$$;

create policy "moderators see moderators" on public.moderators
  for select to authenticated using (public.is_moderator() or user_id = (select auth.uid()));

-------------------------------------------------------------------------------
-- Media assets: one row per uploaded file (written only by the Edge Function)
-------------------------------------------------------------------------------

create table public.media_assets (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles on delete cascade,
  kind        text not null check (kind in ('gif', 'image', 'font', 'evidence')),
  bucket      text not null,
  path        text not null unique,
  sha256      text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  mime        text not null,
  size_bytes  int not null check (size_bytes > 0),
  width       int,
  height      int,
  banned_at   timestamptz,
  created_at  timestamptz not null default now()
);
create index on public.media_assets (sha256);
create index on public.media_assets (owner_id, created_at desc);
create index on public.media_assets (created_at desc);
alter table public.media_assets enable row level security;

create policy "assets readable" on public.media_assets
  for select to authenticated
  using (kind <> 'evidence' or owner_id = (select auth.uid()) or public.is_moderator());
create policy "owners delete own assets" on public.media_assets
  for delete to authenticated
  using (owner_id = (select auth.uid()) and kind <> 'evidence');

create table public.banned_hashes (
  sha256      text primary key check (sha256 ~ '^[0-9a-f]{64}$'),
  kind        text,
  reason      text check (char_length(reason) <= 500),
  banned_by   uuid references public.profiles on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.banned_hashes enable row level security;
create policy "moderators read bans" on public.banned_hashes
  for select to authenticated using (public.is_moderator());

-- Lets clients check end-to-end encrypted attachments (which the server can't
-- see) against the ban list without exposing the whole list.
create function public.banned_among(p_hashes text[])
returns setof text
language sql
security definer
stable
set search_path = ''
as $$
  select sha256 from public.banned_hashes where sha256 = any (p_hashes[1:200]);
$$;

-- An asset the given user may reference: theirs, of the right kind, not banned.
create function public._owns_asset(p_owner uuid, p_path text, p_kind text)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.media_assets
    where path = p_path and owner_id = p_owner and kind = p_kind and banned_at is null
  );
$$;

-------------------------------------------------------------------------------
-- GIF library
-------------------------------------------------------------------------------

create table public.gifs (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles on delete cascade,
  asset_id    uuid not null unique references public.media_assets on delete cascade,
  title       text check (char_length(title) <= 80),
  is_public   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on public.gifs (owner_id, created_at desc);
create index on public.gifs (created_at desc) where is_public;
alter table public.gifs enable row level security;

-- Unlisted GIFs are still readable by id (recipients of a message need them),
-- they just don't show up in the public gallery.
create policy "gifs readable" on public.gifs
  for select to authenticated using (true);
create policy "insert own gifs" on public.gifs
  for insert to authenticated with check (owner_id = (select auth.uid()));
create policy "update own gifs" on public.gifs
  for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "delete own gifs" on public.gifs
  for delete to authenticated using (owner_id = (select auth.uid()));
revoke update on public.gifs from authenticated;
grant update (title, is_public) on public.gifs to authenticated;

create function public.check_gif_asset()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.media_assets
    where id = new.asset_id and owner_id = new.owner_id and kind = 'gif' and banned_at is null
  ) then
    raise exception 'GIF file must be your own, uploaded via upload-media and not banned'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger gifs_check_asset before insert on public.gifs
  for each row execute function public.check_gif_asset();

-------------------------------------------------------------------------------
-- Publishing skins & fonts to the gallery
-------------------------------------------------------------------------------

alter table public.message_skins add column is_public boolean not null default false;
alter table public.user_fonts add column is_public boolean not null default false;

grant update (name, is_public) on public.message_skins to authenticated;

create policy "update own fonts" on public.user_fonts
  for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
revoke update on public.user_fonts from authenticated;
grant update (name, is_public) on public.user_fonts to authenticated;

-- Skin images and font files must be media assets of the owner (i.e. hash-checked).
create function public.check_skin_assets()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.bg_image_path is not null
     and not public._owns_asset(new.owner_id, new.bg_image_path, 'image') then
    raise exception 'background image must be uploaded via upload-media' using errcode = '42501';
  end if;
  if new.border_image_path is not null
     and not public._owns_asset(new.owner_id, new.border_image_path, 'image') then
    raise exception 'border image must be uploaded via upload-media' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger message_skins_check_assets before insert on public.message_skins
  for each row execute function public.check_skin_assets();

create function public.check_font_asset()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public._owns_asset(new.owner_id, new.file_path, 'font') then
    raise exception 'font file must be uploaded via upload-media' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger user_fonts_check_asset before insert on public.user_fonts
  for each row execute function public.check_font_asset();

-------------------------------------------------------------------------------
-- Personal library: skins / fonts / GIFs saved from the gallery
-------------------------------------------------------------------------------

create table public.library_items (
  user_id     uuid not null references public.profiles on delete cascade,
  kind        text not null check (kind in ('skin', 'font', 'gif')),
  item_id     uuid not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, kind, item_id)
);
alter table public.library_items enable row level security;
create policy "own library" on public.library_items
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-------------------------------------------------------------------------------
-- Gallery listings (public, not banned), newest first
-------------------------------------------------------------------------------

create function public.gallery_skins(p_limit int default 30, p_offset int default 0)
returns table (skin jsonb, owner_username text)
language sql
stable
set search_path = ''
as $$
  select to_jsonb(s), p.username
  from public.message_skins s
  join public.profiles p on p.id = s.owner_id
  where s.is_public
    and not exists (
      select 1 from public.media_assets a
      where a.path in (s.bg_image_path, s.border_image_path) and a.banned_at is not null
    )
  order by s.created_at desc
  limit least(p_limit, 100) offset greatest(p_offset, 0);
$$;

create function public.gallery_fonts(p_limit int default 30, p_offset int default 0)
returns table (font jsonb, owner_username text)
language sql
stable
set search_path = ''
as $$
  select to_jsonb(f), p.username
  from public.user_fonts f
  join public.profiles p on p.id = f.owner_id
  where f.is_public
    and not exists (
      select 1 from public.media_assets a where a.path = f.file_path and a.banned_at is not null
    )
  order by f.created_at desc
  limit least(p_limit, 100) offset greatest(p_offset, 0);
$$;

create function public.gallery_gifs(
  p_query text default null,
  p_mine boolean default false,
  p_limit int default 40,
  p_offset int default 0
)
returns table (
  id uuid, owner_id uuid, owner_username text, title text, is_public boolean,
  asset_id uuid, path text, width int, height int, created_at timestamptz
)
language sql
stable
set search_path = ''
as $$
  select g.id, g.owner_id, p.username, g.title, g.is_public,
         a.id, a.path, a.width, a.height, g.created_at
  from public.gifs g
  join public.media_assets a on a.id = g.asset_id and a.banned_at is null
  join public.profiles p on p.id = g.owner_id
  where (case when p_mine then g.owner_id = (select auth.uid()) else g.is_public end)
    and (p_query is null or p_query = '' or g.title ilike '%' || p_query || '%')
  order by g.created_at desc
  limit least(p_limit, 100) offset greatest(p_offset, 0);
$$;

-------------------------------------------------------------------------------
-- Reports
-------------------------------------------------------------------------------

create table public.reports (
  id                 uuid primary key default gen_random_uuid(),
  reporter_id        uuid not null default auth.uid() references public.profiles on delete cascade,
  target_type        text not null check (target_type in ('skin', 'font', 'gif', 'attachment')),
  target_id          uuid,             -- skin / font / gif id
  evidence_asset_id  uuid references public.media_assets on delete set null,
  reason             text not null check (char_length(reason) between 1 and 500),
  status             text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at         timestamptz not null default now(),
  resolved_by        uuid references public.profiles on delete set null,
  resolved_at        timestamptz,
  -- an encrypted chat attachment is reported by sharing a decrypted copy
  check (target_type = 'attachment' or target_id is not null)
);
create index on public.reports (status, created_at desc);
create unique index reports_once_per_target
  on public.reports (reporter_id, target_type, target_id) where status = 'open' and target_id is not null;
alter table public.reports enable row level security;

create policy "file reports" on public.reports
  for insert to authenticated
  with check (
    reporter_id = (select auth.uid()) and status = 'open'
    and (evidence_asset_id is null or exists (
      select 1 from public.media_assets a
      where a.id = evidence_asset_id and a.owner_id = (select auth.uid()) and a.kind = 'evidence'))
  );
create policy "see own reports, moderators all" on public.reports
  for select to authenticated
  using (reporter_id = (select auth.uid()) or public.is_moderator());

-------------------------------------------------------------------------------
-- Moderation (called by the `moderate` Edge Function with the service role)
-------------------------------------------------------------------------------

-- Bans a hash: records it, marks every asset with that hash as banned, unpublishes
-- everything that uses them, and closes the related reports. Returns the storage
-- objects the caller must delete.
create function public.moderation_ban_hash(p_sha256 text, p_reason text, p_moderator uuid)
returns table (bucket text, path text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.banned_hashes (sha256, kind, reason, banned_by)
  values (
    p_sha256,
    (select a.kind from public.media_assets a where a.sha256 = p_sha256 limit 1),
    p_reason,
    p_moderator
  )
  on conflict (sha256) do nothing;

  update public.media_assets a set banned_at = now() where a.sha256 = p_sha256 and a.banned_at is null;

  update public.message_skins s set is_public = false
  where exists (select 1 from public.media_assets a
                where a.sha256 = p_sha256 and a.path in (s.bg_image_path, s.border_image_path));
  update public.user_fonts f set is_public = false
  where exists (select 1 from public.media_assets a where a.sha256 = p_sha256 and a.path = f.file_path);
  update public.gifs g set is_public = false
  where exists (select 1 from public.media_assets a where a.sha256 = p_sha256 and a.id = g.asset_id);

  update public.reports r
  set status = 'actioned', resolved_by = p_moderator, resolved_at = now()
  where r.status = 'open' and (
    r.evidence_asset_id in (select a.id from public.media_assets a where a.sha256 = p_sha256)
    or (r.target_type = 'skin' and r.target_id in (
          select s.id from public.message_skins s join public.media_assets a
            on a.path in (s.bg_image_path, s.border_image_path) where a.sha256 = p_sha256))
    or (r.target_type = 'font' and r.target_id in (
          select f.id from public.user_fonts f join public.media_assets a
            on a.path = f.file_path where a.sha256 = p_sha256))
    or (r.target_type = 'gif' and r.target_id in (
          select g.id from public.gifs g join public.media_assets a
            on a.id = g.asset_id where a.sha256 = p_sha256))
  );

  return query select a.bucket, a.path from public.media_assets a where a.sha256 = p_sha256;
end;
$$;

-- Takes a skin / font / GIF out of the gallery without banning its files.
create function public.moderation_unpublish(p_target_type text, p_target_id uuid, p_moderator uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  case p_target_type
    when 'skin' then update public.message_skins set is_public = false where id = p_target_id;
    when 'font' then update public.user_fonts set is_public = false where id = p_target_id;
    when 'gif'  then update public.gifs set is_public = false where id = p_target_id;
    else raise exception 'unknown target type %', p_target_type;
  end case;
  update public.reports
  set status = 'actioned', resolved_by = p_moderator, resolved_at = now()
  where status = 'open' and target_type = p_target_type and target_id = p_target_id;
end;
$$;

-------------------------------------------------------------------------------
-- Function privileges
-------------------------------------------------------------------------------

revoke execute on function public._owns_asset(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.check_gif_asset() from public, anon, authenticated;
revoke execute on function public.check_skin_assets() from public, anon, authenticated;
revoke execute on function public.check_font_asset() from public, anon, authenticated;
revoke execute on function public.moderation_ban_hash(text, text, uuid) from public, anon, authenticated;
revoke execute on function public.moderation_unpublish(text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.moderation_ban_hash(text, text, uuid) to service_role;
grant execute on function public.moderation_unpublish(text, uuid, uuid) to service_role;

revoke execute on function public.is_moderator() from public, anon;
revoke execute on function public.banned_among(text[]) from public, anon;
revoke execute on function public.gallery_skins(int, int) from public, anon;
revoke execute on function public.gallery_fonts(int, int) from public, anon;
revoke execute on function public.gallery_gifs(text, boolean, int, int) from public, anon;
grant execute on function public.is_moderator() to authenticated;
grant execute on function public.banned_among(text[]) to authenticated;
grant execute on function public.gallery_skins(int, int) to authenticated;
grant execute on function public.gallery_fonts(int, int) to authenticated;
grant execute on function public.gallery_gifs(text, boolean, int, int) to authenticated;

-------------------------------------------------------------------------------
-- Storage
-------------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('gifs', 'gifs', false, 8388608, array['image/gif', 'image/webp']),
  ('evidence', 'evidence', false, 10485760,
     array['image/gif', 'image/webp', 'image/png', 'image/jpeg']);

-- Public buckets are written only by the upload-media function (service role).
drop policy "upload own cosmetics" on storage.objects;
drop policy "update own cosmetics" on storage.objects;
drop policy "cosmetics readable" on storage.objects;
drop policy "delete own cosmetics" on storage.objects;

create policy "media readable" on storage.objects
  for select to authenticated
  using (bucket_id in ('skins', 'fonts', 'gifs'));
create policy "delete own media" on storage.objects
  for delete to authenticated
  using (bucket_id in ('skins', 'fonts', 'gifs')
         and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "moderators read evidence" on storage.objects
  for select to authenticated
  using (bucket_id = 'evidence' and public.is_moderator());
