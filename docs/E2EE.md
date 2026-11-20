# End-to-end encryption in CChat

The server (Supabase) stores and relays messages but can never read them. This
document describes what is encrypted, how, and what the design does **not** protect
against.

All cryptography runs in the client (`app/lib/crypto/e2ee.dart`) using the pure-Dart
[`cryptography`](https://pub.dev/packages/cryptography) package. It behaves the same
on Web, Android, Linux and Windows.

## Keys

| Key | Algorithm | Where it lives |
|---|---|---|
| Identity key (key agreement) | X25519 | Private: on the device + encrypted backup. Public: `profiles.x25519_public_key` |
| Signing key | Ed25519 | Private: on the device + encrypted backup. Public: `profiles.ed25519_public_key` |
| Backup key | Argon2id (m = 19 MiB, t = 2, p = 1) of the user's passphrase | Never stored |
| Conversation key | 256-bit random, one per conversation **epoch** | Wrapped once per member in `conversation_keys` |
| File key | 256-bit random, one per uploaded GIF/image | Inside the encrypted message payload |

On the device, the private keys are kept in the platform secure store
(`flutter_secure_storage`): Android Keystore, Windows Credential Manager, the Linux
Secret Service (libsecret) and, on the Web, browser storage encrypted with WebCrypto.
On the Web this is weaker, so use a desktop or Android app if that matters to you.

### Passphrase backup (multi-device)

When an account is first set up, the user chooses an **encryption passphrase**
(separate from the login password). The private keys are serialized, encrypted with
AES-256-GCM using the Argon2id-derived key (AAD = `cchat-backup-v1|<user id>`), and
stored in `key_backups`. RLS limits that table to its owner. On a new device, the
user enters the passphrase to restore the keys. A forgotten passphrase cannot be
recovered: resetting creates new keys, and older messages become unreadable for that user.

## Conversations and epochs

Each conversation has a symmetric key per *epoch*. To give a member access, the
sender wraps the conversation key for them:

```
shared  = X25519(sender_priv, recipient_pub)
kek     = HKDF-SHA256(shared, salt = "<conversation id>|<epoch>",
                      info = "cchat-wrap-v1|<sender id>|<recipient id>")
wrapped = AES-256-GCM(kek, conversation_key,
                      aad = "cchat-wrap-v1|<conv>|<epoch>|<sender>|<recipient>")
```

**Every membership change starts a new epoch** with a fresh random key:

* **Create** a chat: epoch 1, wrapped for every member (`create_conversation`).
* **Add** a member: new epoch, wrapped for old + new members in the same
  transaction (`add_group_members`). New members cannot read history.
* **Remove** a member: new epoch for the remaining members (`remove_group_member`).
  The removed member cannot read anything sent afterwards.
* **Leave**: the leaver cannot rotate meaningfully because they know the key. The
  group is flagged `rotation_needed`, and the server rejects new messages until a
  remaining member rotates. The client does this automatically before sending.

The SQL functions check that the wrapped keys cover **exactly** the current members,
and the message trigger rejects messages that don't use the current epoch.

## Messages

The plaintext payload is JSON:

```json
{ "v": 1, "t": "text", "text": "hi!", "style": { "skin": "<uuid>", "font": "<uuid>" } }
{ "v": 1, "t": "gif",  "gif": { "src": "file", "path": "<conv>/<uuid>.bin", "key": "…", "w": 160, "h": 120 }, "style": {} }
{ "v": 1, "t": "gif",  "gif": { "src": "remote", "url": "https://media.giphy.com/…", "w": 200, "h": 150 }, "style": {} }
```

It is encrypted with AES-256-GCM using the conversation key (random 96-bit nonce,
AAD = `cchat-msg-v1|<conv>|<epoch>|<sender id>`). The sender then signs
`"cchat-sig-v1|<conv>|<epoch>|<sender>|" ‖ nonce ‖ ciphertext` with Ed25519. Receivers
check the signature against the sender's published Ed25519 key before decrypting.
Without the signature, any member could forge messages "from" another member,
because they all share the group key.

The server only sees: conversation id, sender id, epoch, timestamp, ciphertext length.

### GIFs

* **Uploaded GIFs and images** are encrypted with their own random key before upload
  (`attachments` bucket, `<conversation id>/<uuid>.bin`). Only members can download
  the ciphertext, and only holders of the message can decrypt it.
* **GIF search** goes through the `gif-search` Edge Function, so the GIPHY API key
  stays on the server and GIPHY doesn't see who searched for what. The chosen GIF's
  URL is inside the encrypted message. *Displaying* it still downloads it from
  GIPHY's CDN, which exposes the viewer's IP address to GIPHY. Upload the GIF instead
  if that matters.

### Skins and fonts

Message skins (bubble textures) and custom fonts are **profile cosmetics**, like an
avatar. Other users must be able to download them to render your messages, so the
files are readable by all signed-in users and are not end-to-end encrypted. *Which*
skin and font a message uses is in the encrypted payload. Don't upload anything
private as a skin.

## Verifying contacts (safety numbers)

Public keys come from the server, so a malicious server could swap in its own key
when a chat is created or rotated (a man-in-the-middle attack). To detect this, each
user has a **safety number**: a 60-digit fingerprint of their public keys, shown in
*Customize* (your own) and *Chat info* (your contacts'). Compare it in person or over
a call.

## Known limitations (compared to Signal)

* **No forward secrecy within an epoch.** If a device is compromised, messages of the
  epochs that device can access can be decrypted. The keys change only on membership
  changes (and when someone resets keys).
* **Metadata is visible to the server:** who talks to whom, when, group membership,
  and message sizes.
* **Trust on first use** of public keys, unless users compare safety numbers.
* **Web key storage** is weaker than on native platforms.
* Deleting a message deletes the ciphertext row. It can't un-send content that
  another device has already decrypted.
