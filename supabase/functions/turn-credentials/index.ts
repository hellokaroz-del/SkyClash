// Supabase Edge Function: turn-credentials
// Hands a signed-in player short-lived TURN relay credentials from Cloudflare, so two players whose home networks
// block a direct connection can still play together. The Cloudflare token stays here as a secret; the page only
// gets ICE servers that stop working after a day. Setup: lobby/turn-setup.md
//
// Secrets (Supabase > Edge Functions > Secrets): CF_TURN_KEY_ID, CF_TURN_API_TOKEN
// Keep "Verify JWT" on: only signed-in players can ask.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const id = Deno.env.get('CF_TURN_KEY_ID'), token = Deno.env.get('CF_TURN_API_TOKEN');
  if (!id || !token) return json({ error: 'not_configured' }, 500);
  const r = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${id}/credentials/generate-ice-servers`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ttl: 86400 }),
  });
  if (!r.ok) return json({ error: 'cloudflare_' + r.status }, 502);
  const data = await r.json();
  // older responses give one object, newer ones a list; either way hand back a list
  const list = Array.isArray(data.iceServers) ? data.iceServers : data.iceServers ? [data.iceServers] : [];
  // browsers stall on port 53, so those addresses are dropped (Cloudflare's own advice)
  const iceServers = list.map((s: { urls: string | string[] }) => ({ ...s, urls: ([] as string[]).concat(s.urls).filter((u) => !/:53(\?|$)/.test(u)) }))
    .filter((s: { urls: string[] }) => s.urls.length);
  return json({ iceServers });
});
