// User sign-in: associates the connection with a user id so the server can send to
// that user directly and terminate their connections.
import { arc, readForm, userIdFor, json } from '@/lib/arc';

export async function POST(request) {
  const { socket_id: socketId, name } = await readForm(request);
  return json(arc().server.authenticateUser(socketId, { id: userIdFor(name), name }));
}
