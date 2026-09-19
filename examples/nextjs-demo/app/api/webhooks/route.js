// Receives Arc's webhooks, verifies the signature with the server SDK, and keeps the
// last 50 events in memory so the page can show them.
import { arc, json } from '@/lib/arc';

export const dynamic = 'force-dynamic';

const store = (globalThis.__arcWebhooks ??= []);

export async function POST(request) {
  const rawBody = await request.text();
  const headers = Object.fromEntries(request.headers);
  const webhook = arc().server.webhook({ headers, rawBody });

  if (!webhook.isValid()) return json({ error: 'invalid signature' }, 401);

  for (const event of webhook.getEvents()) {
    store.unshift({ ...event, received_at: Date.now() });
  }
  store.splice(50);
  return json({ ok: true });
}

export async function GET() {
  return json({ events: store });
}
