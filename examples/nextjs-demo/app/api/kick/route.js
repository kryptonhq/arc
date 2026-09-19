// Closes every connection signed in as a user.
import { arc, userIdFor, json } from '@/lib/arc';

export async function POST(request) {
  const { user } = await request.json();
  await arc().server.terminateUserConnections(userIdFor(user));
  return json({ ok: true });
}
