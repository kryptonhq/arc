// Shared helpers for driving the unmodified client SDK against a running Arc.
//
// Required environment: ARC_HOST, ARC_PORT, ARC_APP_ID, ARC_APP_KEY, ARC_APP_SECRET,
// ARC_MASTER_KEY (base64, for encrypted channels).
import crypto from 'node:crypto';
import http from 'node:http';
import Pusher from 'pusher-js';

export const env = {
  host: process.env.ARC_HOST ?? 'localhost',
  port: Number(process.env.ARC_PORT ?? 4010),
  appId: process.env.ARC_APP_ID,
  key: process.env.ARC_APP_KEY,
  secret: process.env.ARC_APP_SECRET,
  masterKey: process.env.ARC_MASTER_KEY,
};

const hmac = (data) => crypto.createHmac('sha256', env.secret).update(data).digest('hex');

// The application backend's auth endpoint, as a customer would write it.
export function startAuthServer() {
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      const params = new URLSearchParams(body);
      const socketId = params.get('socket_id');
      const url = new URL(req.url, 'http://x');
      let payload;

      if (url.pathname === '/auth/user') {
        const userData = JSON.stringify({ id: params.get('user_id') ?? 'signed-in-user', name: 'Test' });
        payload = { auth: `${env.key}:${hmac(`${socketId}::user::${userData}`)}`, user_data: userData };
      } else if (url.pathname === '/auth/deny') {
        res.writeHead(403);
        return res.end('forbidden');
      } else if (url.pathname === '/auth/bad') {
        payload = { auth: `${env.key}:${'0'.repeat(64)}` };
      } else {
        const channel = params.get('channel_name');
        if (channel.startsWith('presence-')) {
          const channelData = JSON.stringify({ user_id: params.get('user_id'), user_info: { name: params.get('user_id') } });
          payload = { auth: `${env.key}:${hmac(`${socketId}:${channel}:${channelData}`)}`, channel_data: channelData };
        } else {
          payload = { auth: `${env.key}:${hmac(`${socketId}:${channel}`)}` };
          if (channel.startsWith('private-encrypted-')) {
            payload.shared_secret = channelKey(channel).toString('base64');
          }
        }
      }

      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(payload));
    });
  });

  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

export function channelKey(channel) {
  // SHA-256(channel name || master key), the derivation the server SDKs use.
  return crypto.createHash('sha256').update(Buffer.concat([Buffer.from(channel), Buffer.from(env.masterKey, 'base64')])).digest();
}

export function client(authServer, { userId, authPath = '/auth' } = {}) {
  const base = `http://127.0.0.1:${authServer.address().port}`;
  return new Pusher(env.key, {
    wsHost: env.host,
    wsPort: env.port,
    forceTLS: false,
    enabledTransports: ['ws'],
    cluster: 'unused',
    channelAuthorization: { endpoint: base + authPath, transport: 'ajax', params: userId ? { user_id: userId } : {} },
    userAuthentication: { endpoint: base + '/auth/user', transport: 'ajax', params: userId ? { user_id: userId } : {} },
  });
}

// Signed HTTP API call, implemented independently of the server.
export async function api(method, path, body, query = {}) {
  const params = { auth_key: env.key, auth_timestamp: String(Math.floor(Date.now() / 1000)), auth_version: '1.0', ...query };
  const raw = body === undefined ? '' : JSON.stringify(body);
  if (raw) params.body_md5 = crypto.createHash('md5').update(raw).digest('hex');
  const sorted = Object.keys(params).sort().map((k) => `${k}=${params[k]}`).join('&');
  params.auth_signature = hmac(`${method}\n${path}\n${sorted}`);
  const url = `http://${env.host}:${env.port}${path}?${new URLSearchParams(params)}`;
  const res = await fetch(url, { method, body: raw || undefined, headers: { 'content-type': 'application/json' } });
  const text = await res.text();
  return { status: res.status, body: text, json: () => JSON.parse(text) };
}

export const trigger = (channel, name, data, extra = {}) =>
  api('POST', `/apps/${env.appId}/events`, { name, channel, data: JSON.stringify(data), ...extra });

export function once(target, event, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out waiting for ${event}`)), timeout);
    target.bind(event, (data, meta) => {
      clearTimeout(timer);
      resolve(data ?? meta);
    });
  });
}

export function connected(sdkClient, timeout = 5000) {
  return new Promise((resolve, reject) => {
    if (sdkClient.connection.state === 'connected') return resolve();
    const timer = setTimeout(() => reject(new Error('connect timeout')), timeout);
    sdkClient.connection.bind('connected', () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

export async function subscribed(sdkClient, name) {
  const channel = sdkClient.subscribe(name);
  if (channel.subscribed) return channel;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`subscribe timeout: ${name}`)), 5000);
    channel.bind('pusher:subscription_succeeded', () => {
      clearTimeout(timer);
      resolve();
    });
    channel.bind('pusher:subscription_error', (e) => {
      clearTimeout(timer);
      reject(new Error(`subscription_error ${JSON.stringify(e)}`));
    });
  });
  return channel;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
