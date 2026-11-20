-- Message skins = background + border.
--
-- Background: theme colour, solid colour, two-colour gradient, or image
--             (cover / tile / stretch / nine_slice).
-- Border:     none, solid line (colour + width), or image frame
--             (a 9-slice frame image whose corners stay intact).
-- Plus a corner radius for the bubble and the text colour (already existing).

alter table public.message_skins rename column image_path to bg_image_path;
alter table public.message_skins rename column fit to bg_fit;
alter table public.message_skins alter column bg_image_path drop not null;

alter table public.message_skins
  -- existing rows were image backgrounds
  add column bg_type text not null default 'image'
    check (bg_type in ('theme', 'color', 'gradient', 'image')),
  add column bg_color text check (bg_color ~ '^#[0-9A-Fa-f]{6}$'),
  add column bg_color2 text check (bg_color2 ~ '^#[0-9A-Fa-f]{6}$'),
  add column border_type text not null default 'none'
    check (border_type in ('none', 'solid', 'image')),
  add column border_color text check (border_color ~ '^#[0-9A-Fa-f]{6}$'),
  -- line width (solid) or frame thickness on screen (image), logical pixels
  add column border_width int not null default 0 check (border_width between 0 and 24),
  add column border_radius int not null default 18 check (border_radius between 0 and 40),
  -- path in the "skins" bucket: <owner_id>/<file>
  add column border_image_path text,
  -- size of the frame's corners/edges in the border image, in image pixels
  add column border_slice int not null default 0 check (border_slice between 0 and 1024);

alter table public.message_skins alter column bg_type set default 'color';

alter table public.message_skins
  add constraint message_skins_bg_complete check (
    case bg_type
      when 'color'    then bg_color is not null
      when 'gradient' then bg_color is not null and bg_color2 is not null
      when 'image'    then bg_image_path is not null
      else true
    end
  ),
  add constraint message_skins_border_complete check (
    case border_type
      when 'solid' then border_color is not null and border_width > 0
      when 'image' then border_image_path is not null and border_slice > 0 and border_width > 0
      else true
    end
  ),
  add constraint message_skins_paths_owned check (
    (bg_image_path is null or split_part(bg_image_path, '/', 1) = owner_id::text)
    and (border_image_path is null or split_part(border_image_path, '/', 1) = owner_id::text)
  );

-- Skins are created once and replaced rather than edited, but owners may rename them.
revoke update on public.message_skins from authenticated;
grant update (name) on public.message_skins to authenticated;
