// Authorizes private, presence, and encrypted channel subscriptions. In a real app
// this is where you check that the signed-in user may join the channel.
import { arc, readForm, userIdFor, json } from '@/lib/arc';
import { colorFor } from '@/lib/palette';

export async function POST(request) {
  const { socket_id: socketId, channel_name: channel, name } = await readForm(request);
  const { server } = arc();

  if (channel.startsWith('presence-')) {
    const id = userIdFor(name);
    return json(server.authorizeChannel(socketId, channel, { user_id: id, user_info: { name, color: colorFor(id) } }));
  }

  return json(server.authorizeChannel(socketId, channel));
}
