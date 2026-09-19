// Sends an event to one signed-in user, wherever they are connected.
import { arc, userIdFor, json } from '@/lib/arc';

export async function POST(request) {
  const { to, from } = await request.json();
  await arc().server.sendToUser(userIdFor(to), 'nudge', { from, at: Date.now() });
  return json({ ok: true });
}
