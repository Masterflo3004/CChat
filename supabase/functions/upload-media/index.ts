// Uploads a public media file (GIF, skin image, font) or report evidence.
//
// The server computes the SHA-256 itself, so a client cannot lie about it, and
// rejects files whose hash a moderator has banned. The file type is detected from
// its content, not from the name the client sends.
//
// Request: multipart/form-data with fields `kind` (gif | image | font | evidence),
// optional `width` / `height` hints, and the file in `file`.

import { adminClient, callerOf, corsHeaders, json } from "../_shared/common.ts";

type Kind = "gif" | "image" | "font" | "evidence";

const BUCKET: Record<Kind, string> = { gif: "gifs", image: "skins", font: "fonts", evidence: "evidence" };
const MAX_BYTES: Record<Kind, number> = {
  gif: 8 * 1024 * 1024,
  image: 5 * 1024 * 1024,
  font: 2 * 1024 * 1024,
  evidence: 10 * 1024 * 1024,
};
const ALLOWED: Record<Kind, string[]> = {
  gif: ["image/gif", "image/webp"],
  image: ["image/png", "image/jpeg", "image/webp", "image/gif"],
  font: ["font/ttf", "font/otf"],
  evidence: ["image/gif", "image/webp", "image/png", "image/jpeg"],
};
const EXT: Record<string, string> = {
  "image/gif": "gif", "image/webp": "webp", "image/png": "png", "image/jpeg": "jpg",
  "font/ttf": "ttf", "font/otf": "otf",
};
const UPLOADS_PER_HOUR = 60;

function sniff(b: Uint8Array): string | null {
  const ascii = (from: number, len: number) => String.fromCharCode(...b.subarray(from, from + len));
  if (b.length >= 6 && (ascii(0, 6) === "GIF87a" || ascii(0, 6) === "GIF89a")) return "image/gif";
  if (b.length >= 8 && b[0] === 0x89 && ascii(1, 3) === "PNG") return "image/png";
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 12 && ascii(0, 4) === "RIFF" && ascii(8, 4) === "WEBP") return "image/webp";
  if (b.length >= 4 && ((b[0] === 0 && b[1] === 1 && b[2] === 0 && b[3] === 0) || ascii(0, 4) === "true")) {
    return "font/ttf";
  }
  if (b.length >= 4 && ascii(0, 4) === "OTTO") return "font/otf";
  return null;
}

function dimensions(b: Uint8Array, mime: string): [number, number] | null {
  if (mime === "image/gif" && b.length >= 10) return [b[6] | (b[7] << 8), b[8] | (b[9] << 8)];
  if (mime === "image/png" && b.length >= 24) {
    const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
    return [v.getUint32(16), v.getUint32(20)];
  }
  return null;
}

async function sha256Hex(b: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", b);
  return [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const admin = adminClient();
  const user = await callerOf(req, admin);
  if (!user) return json({ error: "not signed in" }, 401);

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return json({ error: "expected multipart/form-data" }, 400);
  }
  const kind = String(form.get("kind") ?? "") as Kind;
  const file = form.get("file");
  if (!(kind in BUCKET)) return json({ error: "invalid kind" }, 400);
  if (!(file instanceof File)) return json({ error: "missing file" }, 400);
  if (file.size === 0 || file.size > MAX_BYTES[kind]) {
    return json({ error: `file must be between 1 byte and ${MAX_BYTES[kind] / 1024 / 1024} MB` }, 413);
  }

  const bytes: Uint8Array<ArrayBuffer> = new Uint8Array(await file.arrayBuffer());
  const mime = sniff(bytes);
  if (!mime || !ALLOWED[kind].includes(mime)) {
    return json({ error: `unsupported file type for ${kind}` }, 415);
  }
  const sha256 = await sha256Hex(bytes);

  const { data: banned } = await admin.from("banned_hashes").select("sha256").eq("sha256", sha256).maybeSingle();
  if (banned) return json({ error: "This file has been banned by the moderators.", code: "banned" }, 403);

  // Simple rate limit.
  const since = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await admin.from("media_assets").select("id", { count: "exact", head: true })
    .eq("owner_id", user.id).gte("created_at", since);
  if ((count ?? 0) >= UPLOADS_PER_HOUR) return json({ error: "too many uploads, try again later" }, 429);

  // Same user uploading the same file again: reuse it.
  const { data: existing } = await admin.from("media_assets").select()
    .eq("owner_id", user.id).eq("sha256", sha256).eq("kind", kind).is("banned_at", null).maybeSingle();
  if (existing) return json(existing);

  let size = dimensions(bytes, mime);
  if (!size) {
    const w = Number(form.get("width")), h = Number(form.get("height"));
    if (Number.isInteger(w) && Number.isInteger(h) && w > 0 && h > 0 && w <= 10000 && h <= 10000) size = [w, h];
  }

  const bucket = BUCKET[kind];
  const path = `${user.id}/${crypto.randomUUID()}.${EXT[mime]}`;
  const { error: upErr } = await admin.storage.from(bucket).upload(path, bytes, { contentType: mime });
  if (upErr) return json({ error: `storage: ${upErr.message}` }, 500);

  const { data: row, error: insErr } = await admin.from("media_assets").insert({
    owner_id: user.id, kind, bucket, path, sha256, mime,
    size_bytes: bytes.length, width: size?.[0] ?? null, height: size?.[1] ?? null,
  }).select().single();
  if (insErr) {
    await admin.storage.from(bucket).remove([path]);
    return json({ error: `database: ${insErr.message}` }, 500);
  }
  return json(row, 201);
});
