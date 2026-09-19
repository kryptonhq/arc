// Publishes a chat message. The sender's socket_id is passed so Arc does not echo the
// message back to the tab that sent it (it renders its own copy immediately).
import { arc, userIdFor, json } from '@/lib/arc';

export async function POST(request) {
  const { text, name, socketId } = await request.json();
  if (!text || !String(text).trim()) return json({ error: 'empty message' }, 400);

  const message = { id: crypto.randomUUID(), text: String(text).slice(0, 500), name, userId: userIdFor(name), at: Date.now() };
  await arc().server.trigger('demo-chat', 'message', message, { socket_id: socketId });
  return json(message);
}
