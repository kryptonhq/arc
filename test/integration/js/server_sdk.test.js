// The Python server SDK, used the way a Django backend uses it, against clients
// connected with the JavaScript client SDK.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import Pusher from 'pusher-js';
import { env, startAuthServer, client, once, connected, subscribed, sleep } from './helpers.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const python = process.env.ARC_PYTHON ?? path.join(here, '../python/.venv/bin/python');
const script = path.join(here, '../python/sdk_actions.py');

function sdk(action, args = {}) {
  const out = execFileSync(python, [script, action, JSON.stringify(args)], { env: process.env }).toString();
  return JSON.parse(out);
}

let auth;
const clients = [];
const make = (opts) => {
  const c = client(auth, opts);
  clients.push(c);
  return c;
};
const uid = () => crypto.randomBytes(4).toString('hex');

before(async () => {
  auth = await startAuthServer();
});

after(() => {
  clients.forEach((c) => c.disconnect());
  auth?.closeAllConnections();
  auth?.close();
});

test('trigger reaches a connected client', async () => {
  const name = `orders-${uid()}`;
  const p = make();
  const channel = await subscribed(p, name);
  const received = once(channel, 'created');
  assert.deepEqual(sdk('trigger', { channels: [name], event: 'created', data: { id: 7 } }), {});
  assert.deepEqual(await received, { id: 7 });
});

test('trigger to several channels with socket_id exclusion', async () => {
  const [n1, n2] = [`a-${uid()}`, `b-${uid()}`];
  const [p, q] = [make(), make()];
  await Promise.all([connected(p), connected(q)]);
  const [p1, q1, q2] = await Promise.all([subscribed(p, n1), subscribed(q, n1), subscribed(q, n2)]);
  let echoed = false;
  p1.bind('e', () => (echoed = true));
  const both = Promise.all([once(q1, 'e'), once(q2, 'e')]);
  sdk('trigger', { channels: [n1, n2], event: 'e', data: 'plain string', socket_id: p.connection.socket_id });
  assert.deepEqual(await both, ['plain string', 'plain string']);
  await sleep(200);
  assert.equal(echoed, false);
});

test('trigger_batch', async () => {
  const name = `batch-${uid()}`;
  const channel = await subscribed(make(), name);
  const got = [];
  const done = new Promise((resolve) =>
    channel.bind('n', (d) => {
      got.push(d.i);
      if (got.length === 3) resolve();
    })
  );
  sdk('trigger_batch', { batch: [0, 1, 2].map((i) => ({ channel: name, name: 'n', data: { i } })) });
  await done;
  assert.deepEqual(got, [0, 1, 2]);
});

test('channel queries', async () => {
  const name = `presence-sdk-${uid()}`;
  await subscribed(make({ userId: 'dj' }), name);

  const all = sdk('channels_info', { prefix: 'presence-sdk-', attributes: ['user_count'] });
  assert.deepEqual(all.channels[name], { user_count: 1 });
  assert.deepEqual(sdk('channel_info', { channel: name, attributes: ['user_count'] }), { occupied: true, user_count: 1 });
  assert.deepEqual(sdk('users_info', { channel: name }), { users: [{ id: 'dj' }] });
});

test('SDK-generated channel auth is accepted', async () => {
  const name = `presence-auth-${uid()}`;
  const p = new Pusher(env.key, {
    wsHost: env.host, wsPort: env.port, forceTLS: false, enabledTransports: ['ws'], cluster: 'unused',
    channelAuthorization: {
      customHandler: ({ socketId, channelName }, callback) =>
        callback(null, sdk('authorize', { channel: channelName, socket_id: socketId, custom_data: { user_id: 'from-django' } })),
    },
  });
  clients.push(p);
  const channel = await subscribed(p, name);
  assert.equal(channel.members.me.id, 'from-django');
});

test('SDK-generated user auth, send_to_user, and terminate_user_connections', async () => {
  const userId = `django-${uid()}`;
  const p = new Pusher(env.key, {
    wsHost: env.host, wsPort: env.port, forceTLS: false, enabledTransports: ['ws'], cluster: 'unused',
    userAuthentication: {
      customHandler: ({ socketId }, callback) =>
        callback(null, sdk('authenticate_user', { socket_id: socketId, user_data: { id: userId } })),
    },
  });
  clients.push(p);
  await connected(p);
  p.signin();
  await sleep(500);

  const notice = once(p.user, 'hello');
  sdk('send_to_user', { user_id: userId, event: 'hello', data: { hi: true } });
  assert.deepEqual(await notice, { hi: true });

  const closed = new Promise((resolve) => p.connection.bind('state_change', (s) => s.current !== 'connected' && resolve()));
  sdk('terminate', { user_id: userId });
  await closed;
});

test('encrypted channel publish through the SDK decrypts in the client', { skip: !env.masterKey }, async () => {
  const name = `private-encrypted-${uid()}`;
  const channel = await subscribed(make(), name);
  const received = once(channel, 'sealed');
  assert.deepEqual(sdk('trigger', { channels: [name], event: 'sealed', data: { plan: 'launch' } }), {});
  assert.deepEqual(await received, { plan: 'launch' });
});

test('an invalid signature is rejected as 401', () => {
  const result = sdk('bad_secret');
  assert.equal(result.error, 'PusherBadAuth');
});

test('webhooks are signed so the SDK validates them, and flapping is debounced', { skip: !process.env.ARC_WEBHOOK_PORT }, async () => {
  const received = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      received.push({ key: req.headers['x-pusher-key'], signature: req.headers['x-pusher-signature'], body });
      res.end('ok');
    });
  });
  await new Promise((r) => server.listen(Number(process.env.ARC_WEBHOOK_PORT), '127.0.0.1', r));

  try {
    const name = `hooked-${uid()}`;
    const p = make();
    await subscribed(p, name);
    await sleep(1000);

    // Flap: leave and rejoin inside the debounce window.
    p.unsubscribe(name);
    await sleep(200);
    await subscribed(p, name);
    await sleep(3000);

    const events = received.flatMap((r) => JSON.parse(r.body).events).filter((e) => e.channel === name);
    assert.deepEqual(events.map((e) => e.name), ['channel_occupied']);

    const hook = received.find((r) => r.body.includes(name));
    const validated = sdk('validate_webhook', { key: hook.key, signature: hook.signature, body_b64: Buffer.from(hook.body).toString('base64') });
    assert.ok(validated && validated.events, 'SDK rejected the webhook signature');
  } finally {
    server.close();
  }
});
