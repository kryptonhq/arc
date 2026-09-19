// Publishes to an end-to-end encrypted channel. The server SDK encrypts with the
// app's master key before sending; Arc only ever sees ciphertext.
import { arc, json } from '@/lib/arc';

export async function POST(request) {
  const { text, name } = await request.json();
  await arc().server.trigger('private-encrypted-demo', 'note', { text: String(text).slice(0, 500), by: name, at: Date.now() });
  return json({ ok: true });
}
