// GIF search proxy.
//
// Keeps the GIPHY API key on the server and means GIPHY never sees the user's
// search terms together with their IP address. (Loading the chosen GIF still
// fetches it from GIPHY's CDN; users who want full privacy can upload GIFs,
// which are end-to-end encrypted.)
//
// Secret: supabase secrets set GIPHY_API_KEY=...

const GIPHY_KEY = Deno.env.get("GIPHY_API_KEY");
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

type GiphyImage = { url?: string; width?: string; height?: string };
type GiphyGif = {
  id: string;
  title?: string;
  images: { fixed_width?: GiphyImage; fixed_width_small?: GiphyImage; downsized?: GiphyImage };
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!GIPHY_KEY) return json({ error: "GIPHY_API_KEY is not configured" }, 500);

  let q = "";
  let offset = 0;
  try {
    const body = await req.json();
    q = typeof body?.q === "string" ? body.q.trim().slice(0, 100) : "";
    offset = Number.isInteger(body?.offset) ? Math.min(Math.max(body.offset, 0), 4999) : 0;
  } catch {
    // empty body -> trending
  }

  const params = new URLSearchParams({
    api_key: GIPHY_KEY,
    limit: "24",
    offset: String(offset),
    rating: "pg-13",
  });
  const endpoint = q ? "search" : "trending";
  if (q) params.set("q", q);

  const res = await fetch(`https://api.giphy.com/v1/gifs/${endpoint}?${params}`);
  if (!res.ok) return json({ error: `GIF provider returned ${res.status}` }, 502);
  const data = (await res.json()) as { data: GiphyGif[] };

  const results = data.data
    .map((g) => {
      const full = g.images.fixed_width ?? g.images.downsized;
      const preview = g.images.fixed_width_small ?? full;
      if (!full?.url || !preview?.url) return null;
      return {
        id: g.id,
        title: g.title ?? null,
        url: full.url,
        preview: preview.url,
        w: Number(full.width ?? 200),
        h: Number(full.height ?? 200),
      };
    })
    .filter((r) => r !== null);

  return json({ results });
});
