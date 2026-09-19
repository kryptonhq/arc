// Channel queries through Arc's HTTP API.
import { arc, json } from '@/lib/arc';

export const dynamic = 'force-dynamic';

export async function GET() {
  const { server } = arc();
  const [all, presence] = await Promise.all([
    server.get({ path: '/channels' }).then((r) => r.json()),
    server.get({ path: '/channels', params: { filter_by_prefix: 'presence-', info: 'user_count' } }).then((r) => r.json()),
  ]);
  const channels = Object.keys(all.channels).sort().map((name) => ({
    name,
    users: presence.channels[name]?.user_count ?? null,
  }));
  return json({ channels });
}
