// Server-side connection to Arc, using the Channels protocol v7 server SDK for Node.
//
// Credentials come from ARC_CREDENTIALS_FILE (written by the compose stack's seed step)
// or from ARC_APP_ID / ARC_APP_KEY / ARC_APP_SECRET / ARC_MASTER_KEY.
import fs from 'node:fs';
import Pusher from 'pusher';

function readCredentials() {
  const file = process.env.ARC_CREDENTIALS_FILE;
  if (file && fs.existsSync(file)) {
    const c = JSON.parse(fs.readFileSync(file, 'utf8'));
    return { appId: String(c.id), key: c.key, secret: c.secret, masterKey: c.encryption_master_key };
  }
  return {
    appId: process.env.ARC_APP_ID,
    key: process.env.ARC_APP_KEY,
    secret: process.env.ARC_APP_SECRET,
    masterKey: process.env.ARC_MASTER_KEY,
  };
}

let cached;

export function arc() {
  if (cached) return cached;
  const creds = readCredentials();
  if (!creds.appId || !creds.key || !creds.secret) {
    throw new Error('Arc credentials missing: set ARC_CREDENTIALS_FILE or ARC_APP_ID/ARC_APP_KEY/ARC_APP_SECRET');
  }

  const server = new Pusher({
    appId: creds.appId,
    key: creds.key,
    secret: creds.secret,
    host: process.env.ARC_API_HOST || 'localhost',
    port: process.env.ARC_API_PORT || '4000',
    useTLS: process.env.ARC_API_TLS === 'true',
    ...(creds.masterKey ? { encryptionMasterKeyBase64: creds.masterKey } : {}),
  });

  cached = { server, creds };
  return cached;
}

// What the browser needs to connect. The secret never leaves the server.
export function clientConfig() {
  const { creds } = arc();
  return {
    key: creds.key,
    wsHost: process.env.ARC_WS_HOST || 'localhost',
    wsPort: Number(process.env.ARC_WS_PORT || 4000),
    forceTLS: process.env.ARC_WS_TLS === 'true',
    encryption: Boolean(creds.masterKey),
  };
}

// A stable, URL-safe id derived from the display name the visitor picked.
export function userIdFor(name) {
  return String(name || 'guest')
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40) || 'guest';
}

export async function readForm(request) {
  const type = request.headers.get('content-type') || '';
  if (type.includes('application/json')) return request.json();
  return Object.fromEntries(new URLSearchParams(await request.text()));
}

export function json(body, status = 200) {
  return Response.json(body, { status });
}
