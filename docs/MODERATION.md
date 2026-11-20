# Moderation

CChat moderates public media (GIF library, skin images, fonts) by **file hash**.

## How uploads are checked

```
app ──multipart──▶ upload-media (Edge Function, service role)
                    1. who is calling? (JWT)
                    2. detect the type from the file's bytes (not its name)
                    3. SHA-256 of the bytes  ──▶ banned_hashes? ──yes──▶ 403 "banned"
                    4. store in the bucket (gifs / skins / fonts / evidence)
                    5. insert media_assets row (owner, path, sha256, size, dimensions)
```

* The hash is computed **on the server**, so a client can't lie about it.
* Clients can't write to the `gifs`, `skins` and `fonts` buckets directly (no storage
  insert policy). `gifs`, `message_skins` and `user_fonts` rows are checked by triggers:
  they must reference a non-banned `media_assets` row owned by the same user.
* There is a simple rate limit of 60 uploads per user per hour.

## Reports

Anyone can report a gallery skin, font or GIF (gallery ⚑ button, or long-press a
message → *Report GIF / skin / font*). End-to-end encrypted GIFs are reported by
uploading a decrypted copy as **evidence** (`evidence` bucket, visible to moderators only),
after the reporter confirms.

## Moderator tools

Make someone a moderator:

```sql
insert into public.moderators (user_id)
select id from public.profiles where username = 'their_username';
```

Moderators get a **Moderation** entry in *Customize* with three tabs:

| Tab | What you can do |
|---|---|
| Reports | Preview the reported item and its files. **Ban image / font file**, **Remove from gallery** (no ban) or **Dismiss** |
| Recent uploads | Every new public upload with uploader and size. **Ban** proactively |
| Banned | All banned hashes with reason. **Unban** |

Every action goes through the `moderate` Edge Function, which checks that the caller is
a moderator.

**Banning a file** (`moderation_ban_hash`):

1. adds its SHA-256 to `banned_hashes`
2. marks **every** asset with that hash as banned (also other users' copies, in any bucket)
3. unpublishes every skin, font and GIF that uses it
4. closes the related open reports
5. deletes all those files from storage

From then on, uploading the same file is refused for everyone. Apps also hash-check
downloaded media and encrypted GIFs against the ban list (`banned_among`), so cached or
private copies are hidden too.

## Limitations

* **Exact hashes only.** Changing a single byte (re-encoding, cropping, adding a frame)
  gives a new hash. Hash bans stop re-uploads of the same file, not similar ones. A
  next step would be a perceptual hash (e.g. pHash/dHash), computed server-side, to
  catch near-duplicates.
* **Private encrypted GIFs** are only checked by clients (see [E2EE.md](E2EE.md)).
* **Text is not moderated.** Messages are end-to-end encrypted. Usernames and gallery
  titles aren't filtered yet.
