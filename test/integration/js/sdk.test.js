import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import nacl from 'tweetnacl';
import { env, startAuthServer, client, api, trigger, once, connected, subscribed, sleep, channelKey } from './helpers.js';

let auth;
const clients = [];
const make = (opts) => {
  const c = client(auth, opts);
  clients.push(c);
  return c;
};
const uid = () => crypto.randomBytes(4).toString('hex');

before(async () => {
  assert.ok(env.key && env.secret && env.appId, 'ARC_APP_ID, ARC_APP_KEY and ARC_APP_SECRET are required');
  auth = await startAuthServer();
});

after(() => {
  clients.forEach((c) => c.disconnect());
  auth?.closeAllConnections();
  auth?.close();
});

test('connects and receives events on a public channel', async () => {
  const p = make();
  await connected(p);
  assert.match(p.connection.socket_id, /^\d+\.\d+$/);

  const name = `public-${uid()}`;
  const channel = await subscribed(p, name);
  const received = once(channel, 'greeting');
  const res = await trigger(name, 'greeting', { hello: 'world' });
  assert.equal(res.status, 200);
  assert.deepEqual(await received, { hello: 'world' });
});

test('socket_id excludes the originating connection', async () => {
  const [a, b] = [make(), make()];
  await Promise.all([connected(a), connected(b)]);
  const name = `room-${uid()}`;
  const [ca, cb] = await Promise.all([subscribed(a, name), subscribed(b, name)]);

  let echoed = false;
  ca.bind('moved', () => (echoed = true));
  const received = once(cb, 'moved');
  await trigger(name, 'moved', {}, { socket_id: a.connection.socket_id });
  await received;
  await sleep(200);
  assert.equal(echoed, false);
});

test('private channels authorize through the backend endpoint', async () => {
  const p = make();
  const name = `private-${uid()}`;
  const channel = await subscribed(p, name);
  const received = once(channel, 'secret');
  await trigger(name, 'secret', { ok: true });
  assert.deepEqual(await received, { ok: true });
});

test('a bad signature surfaces a subscription error with status 401', async () => {
  const p = make({ authPath: '/auth/bad' });
  const channel = p.subscribe(`private-${uid()}`);
  const error = await once(channel, 'pusher:subscription_error');
  assert.equal(error.status, 401);
});

test('presence members see each other, without duplicates for a second connection', async () => {
  const name = `presence-${uid()}`;
  const alice = make({ userId: 'alice' });
  const ca = await subscribed(alice, name);
  assert.equal(ca.members.count, 1);
  assert.equal(ca.members.me.id, 'alice');

  const added = once(ca, 'pusher:member_added');
  const bob = make({ userId: 'bob' });
  const cb = await subscribed(bob, name);
  assert.equal((await added).id, 'bob');
  assert.equal(cb.members.count, 2);
  assert.deepEqual(cb.members.get('alice').info, { name: 'alice' });

  let duplicates = 0;
  ca.bind('pusher:member_added', () => duplicates++);
  const bob2 = make({ userId: 'bob' });
  await subscribed(bob2, name);
  await sleep(300);
  assert.equal(duplicates, 0);
  assert.equal(ca.members.count, 2);

  let removed = 0;
  ca.bind('pusher:member_removed', () => removed++);
  bob.disconnect();
  await sleep(300);
  assert.equal(removed, 0, 'bob still has a connection');
  const removal = once(ca, 'pusher:member_removed');
  bob2.disconnect();
  assert.equal((await removal).id, 'bob');
  assert.equal(ca.members.count, 1);

  const users = await api('GET', `/apps/${env.appId}/channels/${name}/users`);
  assert.deepEqual(users.json(), { users: [{ id: 'alice' }] });
});

test('client events reach other members and are not echoed', async () => {
  const name = `private-${uid()}`;
  const [a, b] = [make(), make()];
  const [ca, cb] = await Promise.all([subscribed(a, name), subscribed(b, name)]);

  let echoed = false;
  ca.bind('client-typing', () => (echoed = true));
  const received = once(cb, 'client-typing');
  assert.equal(ca.trigger('client-typing', { who: 'a' }), true);
  assert.deepEqual(await received, { who: 'a' });
  await sleep(200);
  assert.equal(echoed, false);
});

test('encrypted channels decrypt in the SDK', async () => {
  const name = `private-encrypted-${uid()}`;
  const p = make();
  const channel = await subscribed(p, name);
  const received = once(channel, 'sealed');

  const nonce = nacl.randomBytes(24);
  const box = nacl.secretbox(Buffer.from(JSON.stringify({ plan: 'launch' })), nonce, new Uint8Array(channelKey(name)));
  const data = JSON.stringify({ nonce: Buffer.from(nonce).toString('base64'), ciphertext: Buffer.from(box).toString('base64') });
  const res = await api('POST', `/apps/${env.appId}/events`, { name: 'sealed', channel: name, data });
  assert.equal(res.status, 200, res.body);
  assert.deepEqual(await received, { plan: 'launch' });

  const plain = await trigger(name, 'sealed', { plan: 'leak' });
  assert.equal(plain.status, 400);
});

test('cache channels replay the last event and report misses', async () => {
  const name = `cache-${uid()}`;
  const first = make();
  const miss = new Promise((resolve) => {
    const channel = first.subscribe(name);
    channel.bind('pusher:cache_miss', resolve);
  });
  await miss;

  await trigger(name, 'state', { v: 1 });
  await trigger(name, 'state', { v: 2 });

  const late = make();
  const channel = late.subscribe(name);
  assert.deepEqual(await once(channel, 'state'), { v: 2 });
});

test('user sign-in, user-targeted events, and terminate_connections', async () => {
  const userId = `user-${uid()}`;
  const p = make({ userId });
  await connected(p);
  p.signin();
  const notice = once(p.user, 'notice');
  await sleep(500);

  await api('POST', `/apps/${env.appId}/events`, { name: 'notice', channel: `#server-to-user-${userId}`, data: '{"x":1}' });
  assert.deepEqual(await notice, { x: 1 });

  const closed = new Promise((resolve) => p.connection.bind('state_change', (s) => s.current !== 'connected' && resolve(s.current)));
  const res = await api('POST', `/apps/${env.appId}/users/${userId}/terminate_connections`, {});
  assert.equal(res.status, 200);
  const state = await closed;
  assert.ok(['disconnected', 'failed', 'unavailable', 'connecting'].includes(state), state);
});

test('channel queries through the HTTP API', async () => {
  const name = `presence-q-${uid()}`;
  const p = make({ userId: 'q' });
  await subscribed(p, name);

  const list = await api('GET', `/apps/${env.appId}/channels`, undefined, { filter_by_prefix: 'presence-q-', info: 'user_count' });
  assert.deepEqual(list.json().channels[name], { user_count: 1 });

  const one = await api('GET', `/apps/${env.appId}/channels/${name}`, undefined, { info: 'user_count' });
  assert.deepEqual(one.json(), { occupied: true, user_count: 1 });
});
