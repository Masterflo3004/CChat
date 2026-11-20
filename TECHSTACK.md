# CChat – Tech Stack Plan

A simple chat app backed by **Supabase**, running on **Web, Android, Linux and Windows** from a single codebase.

## TL;DR

| Layer | Choice | Why |
|---|---|---|
| Client framework | **Flutter (Dart), stable channel** | One codebase with first-class targets for Web, Android, Linux *and* Windows. |
| Supabase SDK | **`supabase_flutter`** | Official SDK: Auth, Postgres, Realtime, Storage, Edge Functions; persists sessions on every platform. |
| State management | **Riverpod** (`flutter_riverpod`) | Simple, testable, works well with streams (Realtime). |
| Routing | **`go_router`** | Declarative, URL-aware (matters for Web), auth redirects. |
| Data models | **`freezed` + `json_serializable`** | Immutable models, generated `fromJson`/`toJson`. |
| Backend | **Supabase**: Postgres + RLS, Auth, Realtime, Storage, Edge Functions | Covers the whole backend with no custom server. |
| Local dev | **Supabase CLI** (local stack in Docker, migrations in `supabase/migrations`) | Reproducible schema, safe to test before pushing to the hosted project. |
| Push notifications | **FCM** (Android + Web), triggered by an Edge Function | Desktop gets in-app notifications while running (see below). |
| CI/CD | **GitHub Actions** | Build matrix per platform, migrations deploy, web hosting. |

### Why Flutter over the alternatives

- **React Native / Expo** – great on Android/iOS/Web, but Linux has no maintained official target and Windows support is a separate Microsoft project. Fails the "all four platforms" requirement.
- **Tauri / Electron + React** – excellent for Web + Windows + Linux, but Android needs a second shell (Tauri mobile or Capacitor) with its own quirks. Viable if the team is strongly web/TypeScript-centric; it is the runner-up.
- **Kotlin Multiplatform + Compose** – Web (Wasm) and Linux are not yet as mature, and the Supabase community SDK is less battle-tested than `supabase_flutter`.
- **Flutter** – all four targets are official and stable, and Supabase maintains the Flutter SDK themselves.

---

## Architecture

```
┌─────────────────────── Flutter app (one codebase) ───────────────────────┐
│  UI (widgets)  →  Riverpod providers  →  Repositories  →  supabase_flutter │
│        Web  ·  Android  ·  Linux  ·  Windows                              │
└──────────────────────────────────┬────────────────────────────────────────┘
                                   │ HTTPS / WebSocket
┌──────────────────────────────────▼────────────────────────────────────────┐
│ Supabase                                                                   │
│  Auth (email OTP / password, optional OAuth)                               │
│  Postgres (profiles, conversations, members, messages) + Row Level Security│
│  Realtime (new messages via Postgres Changes, typing/online via Presence)  │
│  Storage (avatars, image attachments, RLS-protected buckets)               │
│  Edge Functions (send push via FCM on new message)                         │
└───────────────────────────────────────────────────────────────────────────┘
```

### Suggested project layout

```
cchat/
├─ app/                       # Flutter project
│  ├─ lib/
│  │  ├─ main.dart            # Supabase.initialize(url, publishableKey)
│  │  ├─ core/                # env config, router, theme
│  │  ├─ features/
│  │  │  ├─ auth/             # sign-in, sign-up, session
│  │  │  ├─ conversations/    # list, create, members
│  │  │  └─ chat/             # message list, composer, realtime stream
│  │  └─ data/                # models (freezed) + repositories
│  ├─ android/ web/ linux/ windows/
│  └─ test/
├─ supabase/
│  ├─ config.toml
│  ├─ migrations/             # SQL schema + RLS policies
│  └─ functions/notify/       # Edge Function: push notifications
└─ .github/workflows/         # CI builds + deploys
```

---

## Supabase backend

### Schema (MVP)

```sql
create table public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  username    text unique not null,
  avatar_url  text,
  created_at  timestamptz not null default now()
);

create table public.conversations (
  id          uuid primary key default gen_random_uuid(),
  name        text,                     -- null for 1:1 chats
  is_group    boolean not null default false,
  created_by  uuid not null references public.profiles(id),
  created_at  timestamptz not null default now()
);

create table public.conversation_members (
  conversation_id uuid references public.conversations on delete cascade,
  user_id         uuid references public.profiles on delete cascade,
  last_read_at    timestamptz,
  primary key (conversation_id, user_id)
);

create table public.messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid not null references public.conversations on delete cascade,
  sender_id       uuid not null references public.profiles(id),
  body            text check (char_length(body) <= 4000),
  attachment_path text,                 -- path in Storage bucket
  created_at      timestamptz not null default now()
);
create index on public.messages (conversation_id, created_at desc);
```

A trigger on `auth.users` inserts the matching `profiles` row on sign-up.

### Row Level Security

RLS is enabled on **every** table. Membership checks go through a
`security definer` helper so policies on `conversation_members` don't recurse:

```sql
create function public.is_member(conv uuid) returns boolean
language sql security definer set search_path = '' stable as $$
  select exists (
    select 1 from public.conversation_members
    where conversation_id = conv and user_id = (select auth.uid())
  );
$$;

alter table public.messages enable row level security;

create policy "members read messages" on public.messages
  for select to authenticated using (public.is_member(conversation_id));

create policy "members send own messages" on public.messages
  for insert to authenticated
  with check (sender_id = (select auth.uid()) and public.is_member(conversation_id));
```

Similar policies cover `conversations`, `conversation_members` and the Storage bucket
(path convention `attachments/<conversation_id>/<file>`).

### Realtime

- **New messages:** subscribe to Postgres Changes on `messages` filtered by
  `conversation_id=eq.<id>` (add `messages` to the `supabase_realtime` publication).
  RLS applies, so users only receive messages they may read.
- **Typing indicators & online status:** Realtime **Presence** on a channel per conversation – no DB writes.
- **Scaling later:** if traffic grows, switch message fan-out to Realtime **Broadcast** (triggered from the DB), which scales better than Postgres Changes.

### Auth

- **Primary:** email + password and/or **email OTP code** (6-digit code). This avoids
  redirect/deep-link handling, which is awkward on Linux and Windows desktop.
- **Optional OAuth (Google/GitHub):** works out of the box on Web and Android (deep link).
  On desktop it needs a custom URL scheme (Windows registry entry, `.desktop` file on Linux)
  or a localhost loopback – add it after the MVP.
- Sessions are persisted by `supabase_flutter` on all platforms; tokens refresh automatically.

### Edge Functions

- `notify`: invoked by a Database Webhook on `messages` insert → looks up recipients'
  device tokens (`device_tokens` table) → sends via **FCM HTTP v1** (service-account secret
  stored with `supabase secrets set`).

---

## Platform-specific notes

| Platform | Build output | Distribution | Notes |
|---|---|---|---|
| **Web** | `flutter build web` | Cloudflare Pages / Netlify / Vercel / GitHub Pages | Add the site URL to Supabase Auth redirect URLs. FCM web push needs a service worker. |
| **Android** | `flutter build appbundle` | Google Play (AAB) or APK sideload | `INTERNET` permission, deep-link intent filter for OAuth, FCM via `firebase_messaging`. |
| **Windows** | `flutter build windows` | **MSIX** (`msix` package) or Inno Setup installer | No FCM; use in-app notifications (`local_notifier`) while the app runs, optional tray icon (`tray_manager`). |
| **Linux** | `flutter build linux` | **AppImage**, **Flatpak** or `.deb` | Needs GTK3 dev libs to build; same notification approach as Windows (`libnotify` via `local_notifier`). Session storage works out of the box. |

**Desktop notifications:** there is no free cross-desktop push service equivalent to FCM, so
desktop clients keep a Realtime connection while open and raise local notifications. This is
normal for desktop chat apps and fine for an MVP.

---

## Supporting packages (Flutter)

| Purpose | Package |
|---|---|
| Supabase | `supabase_flutter` |
| State | `flutter_riverpod` (+ `riverpod_generator`) |
| Routing | `go_router` |
| Models | `freezed`, `json_serializable`, `build_runner` |
| Images / attachments | `file_picker`, `cached_network_image` |
| Notifications | `firebase_messaging` (Android/Web), `local_notifier` (desktop) |
| Desktop polish | `window_manager`, `tray_manager` |
| Config | `--dart-define-from-file=env.json` (Supabase URL + publishable key; never the service-role key) |
| Optional offline cache | `drift` (SQLite, works on all four platforms) |

---

## Tooling & quality

- **Lint:** `flutter_lints` (or `very_good_analysis` for stricter rules).
- **Tests:** unit tests for repositories (mock Supabase client), widget tests for chat UI,
  `integration_test` against the **local Supabase stack**; pgTAP tests for RLS policies
  (`supabase test db`).
- **Types:** keep Dart models in sync with the schema; generate TS types only if Edge Functions need them (`supabase gen types typescript`).

## CI/CD (GitHub Actions)

1. **PR checks:** `flutter analyze`, `flutter test`, `supabase db lint`, RLS tests on a local stack.
2. **Build matrix:** `ubuntu-latest` → Web + Android + Linux; `windows-latest` → Windows (MSIX).
3. **Deploy:** on `main` → `supabase db push` + `supabase functions deploy`, publish web build, attach desktop/Android artifacts to a GitHub Release.

---

## MVP roadmap

1. **Setup** – Flutter project with 4 platforms enabled, Supabase project + CLI, env config.
2. **Auth** – sign-up/sign-in (email + password / OTP), profile creation trigger.
3. **Schema + RLS** – migrations above, RLS tests.
4. **Conversations** – list, create 1:1 and group chats, add members.
5. **Messaging** – paginated history, send, live updates via Realtime.
6. **Presence** – typing indicator, online dots, unread counts (`last_read_at`).
7. **Attachments** – image upload to Storage with signed URLs.
8. **Notifications** – FCM on Android/Web, local notifications on desktop.
9. **Packaging** – MSIX, AppImage/Flatpak, Play Store, web hosting via CI.
