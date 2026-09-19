// Sets the "current status" on a cache channel. Arc retains the last event, so a tab
// opened later receives it immediately on subscribe.
import { arc, json } from '@/lib/arc';

export async function POST(request) {
  const { status, name } = await request.json();
  await arc().server.trigger('cache-demo-status', 'status', { status: String(status).slice(0, 80), by: name, at: Date.now() });
  return json({ ok: true });
}
