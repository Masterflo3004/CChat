// Moderator actions. Only users listed in public.moderators may call this.
//
// { "action": "ban_asset", "asset_id": "...", "reason": "..." }
//     Bans the asset's SHA-256: deletes every copy, unpublishes everything using
//     it, closes related reports, and blocks identical uploads in the future.
// { "action": "unban", "sha256": "..." }
// { "action": "unpublish", "target_type": "skin" | "font" | "gif", "target_id": "..." }
// { "action": "dismiss", "report_id": "..." }

import { adminClient, callerOf, corsHeaders, json } from "../_shared/common.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const admin = adminClient();
  const user = await callerOf(req, admin);
  if (!user) return json({ error: "not signed in" }, 401);
  const { data: mod } = await admin.from("moderators").select("user_id").eq("user_id", user.id).maybeSingle();
  if (!mod) return json({ error: "moderators only" }, 403);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "expected JSON" }, 400);
  }
  const reason = typeof body.reason === "string" ? body.reason.slice(0, 500) : null;

  switch (body.action) {
    case "ban_asset": {
      const { data: asset } = await admin.from("media_assets").select("sha256")
        .eq("id", String(body.asset_id)).maybeSingle();
      if (!asset) return json({ error: "asset not found" }, 404);
      const { data: objects, error } = await admin.rpc("moderation_ban_hash", {
        p_sha256: asset.sha256, p_reason: reason, p_moderator: user.id,
      });
      if (error) return json({ error: error.message }, 500);
      // Delete every stored copy of the banned file.
      const byBucket = new Map<string, string[]>();
      for (const o of (objects ?? []) as { bucket: string; path: string }[]) {
        byBucket.set(o.bucket, [...(byBucket.get(o.bucket) ?? []), o.path]);
      }
      let deleted = 0;
      for (const [bucket, paths] of byBucket) {
        const { data } = await admin.storage.from(bucket).remove(paths);
        deleted += data?.length ?? 0;
      }
      return json({ banned: asset.sha256, deleted_files: deleted });
    }
    case "unban": {
      const sha = String(body.sha256 ?? "");
      const { error } = await admin.from("banned_hashes").delete().eq("sha256", sha);
      if (error) return json({ error: error.message }, 500);
      return json({ unbanned: sha });
    }
    case "unpublish": {
      const { error } = await admin.rpc("moderation_unpublish", {
        p_target_type: String(body.target_type), p_target_id: String(body.target_id), p_moderator: user.id,
      });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }
    case "dismiss": {
      const { error } = await admin.from("reports")
        .update({ status: "dismissed", resolved_by: user.id, resolved_at: new Date().toISOString() })
        .eq("id", String(body.report_id)).eq("status", "open");
      if (error) return json({ error: error.message }, 500);
      return json({ ok: true });
    }
    default:
      return json({ error: "unknown action" }, 400);
  }
});
