'use client';

import { useCallback, useEffect, useRef, useState } from 'react';

const LOBBY = 'presence-demo-lobby';
const CHAT = 'demo-chat';
const STATUS = 'cache-demo-status';
const SECRET = 'private-encrypted-demo';

function randomName() {
  return `guest-${Math.random().toString(36).slice(2, 6)}`;
}

const post = (url, body) =>
  fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then((r) => r.json());

const time = (ms) => new Date(ms).toLocaleTimeString();

export default function Demo({ config }) {
  const [name, setName] = useState(null);
  const [draftName, setDraftName] = useState('');

  useEffect(() => {
    const saved = window.localStorage.getItem('arc-demo-name') || randomName();
    window.localStorage.setItem('arc-demo-name', saved);
    setName(saved);
    setDraftName(saved);
  }, []);

  const rename = (e) => {
    e.preventDefault();
    const next = draftName.trim().slice(0, 30);
    if (!next || next === name) return;
    window.localStorage.setItem('arc-demo-name', next);
    setName(next);
  };

  if (!name) return null;

  return (
    <main className="shell">
      <header className="top">
        <div>
          <h1>
            <span className="dot" /> Arc demo
          </h1>
          <p className="muted">
            Open this page in two browsers (or a private window) with different names to see events flow between
            them. Tabs in the same browser share a name, so they count as one presence member.
          </p>
        </div>
        <form onSubmit={rename} className="row">
          <label className="muted" htmlFor="name">You are</label>
          <input id="name" value={draftName} onChange={(e) => setDraftName(e.target.value)} />
          <button type="submit">Rename</button>
        </form>
      </header>
      {/* Remounting on rename reconnects with the new identity. */}
      <Session key={name} name={name} config={config} />
    </main>
  );
}

function Session({ name, config }) {
  const clientRef = useRef(null);
  const [state, setState] = useState('connecting');
  const [socketId, setSocketId] = useState(null);
  const [log, setLog] = useState([]);
  const [messages, setMessages] = useState([]);
  const [members, setMembers] = useState([]);
  const [me, setMe] = useState(null);
  const [typing, setTyping] = useState({});
  const [status, setStatus] = useState(undefined);
  const [notes, setNotes] = useState([]);
  const [secretError, setSecretError] = useState(null);
  const [signedIn, setSignedIn] = useState(false);
  const [nudges, setNudges] = useState([]);

  const addLog = useCallback((entry) => setLog((l) => [{ ...entry, at: Date.now() }, ...l].slice(0, 30)), []);

  useEffect(() => {
    let client;
    let cancelled = false;

    (async () => {
      const { default: Pusher } = await import('pusher-js/with-encryption');
      if (cancelled) return;

      client = new Pusher(config.key, {
        wsHost: config.wsHost,
        wsPort: config.wsPort,
        wssPort: config.wsPort,
        forceTLS: config.forceTLS,
        enabledTransports: ['ws', 'wss'],
        cluster: 'arc', // required by the SDK, ignored by Arc
        channelAuthorization: { endpoint: '/api/auth/channel', transport: 'ajax', params: { name } },
        userAuthentication: { endpoint: '/api/auth/user', transport: 'ajax', params: { name } },
      });
      clientRef.current = client;

      client.connection.bind('state_change', ({ current }) => {
        setState(current);
        addLog({ kind: 'state', text: current });
      });
      client.connection.bind('connected', () => setSocketId(client.connection.socket_id));
      client.connection.bind('error', (err) => addLog({ kind: 'error', text: JSON.stringify(err?.data ?? err?.error ?? err) }));
      client.bind_global((event, data) => {
        if (!event.startsWith('pusher:')) addLog({ kind: 'event', text: event });
      });

      // Public channel: chat messages published by the server.
      client.subscribe(CHAT).bind('message', (m) => setMessages((all) => [...all, m].slice(-100)));

      // Presence channel: who is here, plus typing indicators sent as client events.
      const lobby = client.subscribe(LOBBY);
      const syncMembers = () => {
        const list = [];
        lobby.members.each((m) => list.push({ id: m.id, ...m.info }));
        setMembers(list);
        setMe(lobby.members.me?.id ?? null);
      };
      lobby.bind('pusher:subscription_succeeded', syncMembers);
      lobby.bind('pusher:member_added', (m) => {
        syncMembers();
        addLog({ kind: 'presence', text: `${m.info?.name ?? m.id} joined` });
      });
      lobby.bind('pusher:member_removed', (m) => {
        syncMembers();
        addLog({ kind: 'presence', text: `${m.info?.name ?? m.id} left` });
      });
      lobby.bind('client-typing', ({ name: who }) => {
        setTyping((t) => ({ ...t, [who]: Date.now() }));
      });

      // Cache channel: the last status is replayed to new subscribers.
      const statusChannel = client.subscribe(STATUS);
      statusChannel.bind('status', setStatus);
      statusChannel.bind('pusher:cache_miss', () => setStatus(null));

      // End-to-end encrypted channel: decrypted in the browser.
      if (config.encryption) {
        const secret = client.subscribe(SECRET);
        secret.bind('note', (n) => setNotes((all) => [n, ...all].slice(0, 20)));
        secret.bind('pusher:subscription_error', (e) => setSecretError(e?.error ?? 'subscription failed'));
      }

      // User sign-in: enables direct messages and remote disconnects.
      client.user.bind('nudge', (n) => {
        setNudges((all) => [n, ...all].slice(0, 5));
        addLog({ kind: 'user', text: `nudged by ${n.from}` });
      });
      client.signin();
      client.user.signinDonePromise?.then(() => setSignedIn(true)).catch(() => setSignedIn(false));
    })();

    return () => {
      cancelled = true;
      client?.disconnect();
    };
  }, [config, name, addLog]);

  // Typing indicators fade after three seconds.
  useEffect(() => {
    const t = setInterval(() => {
      setTyping((all) => Object.fromEntries(Object.entries(all).filter(([, at]) => Date.now() - at < 3000)));
    }, 1000);
    return () => clearInterval(t);
  }, []);

  const client = clientRef.current;

  return (
    <>
      <section className="status-bar">
        <span className={`pill ${state === 'connected' ? 'ok' : 'warn'}`}>{state}</span>
        <span className="muted">socket id</span> <code>{socketId ?? '—'}</code>
        <span className="muted">signed in as</span> <code>{signedIn ? me ?? name : '—'}</code>
        {state !== 'connected' && (
          <button onClick={() => client?.connect()} className="ghost">
            Reconnect
          </button>
        )}
      </section>

      <div className="grid">
        <Chat messages={messages} setMessages={setMessages} name={name} client={client} socketId={socketId} typing={typing} />
        <Presence members={members} me={me} name={name} />
        <Status status={status} name={name} />
        <Secret enabled={config.encryption} notes={notes} error={secretError} name={name} />
        <Users members={members} me={me} name={name} nudges={nudges} />
        <Channels />
        <Webhooks />
        <Log log={log} />
      </div>
    </>
  );
}

function Card({ title, tag, children, wide }) {
  return (
    <section className={`card ${wide ? 'wide' : ''}`}>
      <header>
        <h2>{title}</h2>
        {tag && <code className="tag">{tag}</code>}
      </header>
      {children}
    </section>
  );
}

function Chat({ messages, setMessages, name, client, socketId, typing }) {
  const [text, setText] = useState('');
  const lastTyping = useRef(0);
  const box = useRef(null);

  // Scroll the message list only, never the page.
  useEffect(() => {
    if (box.current) box.current.scrollTop = box.current.scrollHeight;
  }, [messages]);

  const onType = (value) => {
    setText(value);
    // Client events go straight from this browser to the others, not via the server.
    if (Date.now() - lastTyping.current > 1500) {
      client?.channel(LOBBY)?.trigger('client-typing', { name });
      lastTyping.current = Date.now();
    }
  };

  const send = async (e) => {
    e.preventDefault();
    if (!text.trim()) return;
    setText('');
    const message = await post('/api/messages', { text, name, socketId });
    // Arc excludes our own socket from the broadcast, so we render our copy here.
    if (message.id) setMessages((all) => [...all, message]);
  };

  const others = Object.keys(typing).filter((who) => who !== name);

  return (
    <Card title="Chat" tag={CHAT} wide>
      <p className="muted">
        Published by the server with your <code>socket_id</code>, so Arc does not echo it back to you. Typing
        indicators are client events on the presence channel.
      </p>
      <div className="messages" ref={box}>
        {messages.length === 0 && <p className="muted">No messages yet.</p>}
        {messages.map((m) => (
          <div key={m.id} className={`message ${m.name === name ? 'mine' : ''}`}>
            <strong>{m.name}</strong> <span className="muted small">{time(m.at)}</span>
            <div>{m.text}</div>
          </div>
        ))}
      </div>
      <p className="typing muted small">{others.length > 0 ? `${others.join(', ')} typing…` : ' '}</p>
      <form onSubmit={send} className="row">
        <input value={text} onChange={(e) => onType(e.target.value)} placeholder="Say something" />
        <button type="submit">Send</button>
      </form>
    </Card>
  );
}

function Presence({ members, me }) {
  return (
    <Card title="Who's here" tag={LOBBY}>
      <p className="muted">
        A presence channel. Two tabs with the same name count as one member; leaving fires only when the last one closes.
      </p>
      <ul className="members">
        {members.map((m) => (
          <li key={m.id}>
            <span className="avatar" style={{ background: m.color }}>{(m.name ?? m.id).slice(0, 1).toUpperCase()}</span>
            {m.name ?? m.id}
            {m.id === me && <span className="muted small"> (you)</span>}
          </li>
        ))}
      </ul>
    </Card>
  );
}

function Status({ status, name }) {
  const [value, setValue] = useState('');
  const save = async (e) => {
    e.preventDefault();
    if (!value.trim()) return;
    await post('/api/status', { status: value, name });
    setValue('');
  };

  return (
    <Card title="Current status" tag={STATUS}>
      <p className="muted">A cache channel: Arc keeps the last event and replays it to anyone who subscribes later. Set a status, then open a new tab.</p>
      <div className="status">
        {status === undefined && <span className="muted">Loading…</span>}
        {status === null && <span className="muted">Nothing retained yet (cache miss).</span>}
        {status && (
          <>
            <div className="big">{status.status}</div>
            <div className="muted small">
              set by {status.by} at {time(status.at)}
            </div>
          </>
        )}
      </div>
      <form onSubmit={save} className="row">
        <input value={value} onChange={(e) => setValue(e.target.value)} placeholder="e.g. Deploy in progress" />
        <button type="submit">Set</button>
      </form>
    </Card>
  );
}

function Secret({ enabled, notes, error, name }) {
  const [value, setValue] = useState('');
  const send = async (e) => {
    e.preventDefault();
    if (!value.trim()) return;
    await post('/api/secret', { text: value, name });
    setValue('');
  };

  return (
    <Card title="Encrypted notes" tag={SECRET}>
      <p className="muted">
        End-to-end encrypted: the server SDK encrypts, your browser decrypts, and Arc only relays ciphertext.
      </p>
      {!enabled && <p className="muted">This app has no encryption master key.</p>}
      {error && <p className="error">{error}</p>}
      <ul className="notes">
        {notes.map((n) => (
          <li key={n.at + n.text}>
            🔒 {n.text} <span className="muted small">— {n.by}</span>
          </li>
        ))}
      </ul>
      {enabled && (
        <form onSubmit={send} className="row">
          <input value={value} onChange={(e) => setValue(e.target.value)} placeholder="A secret note" />
          <button type="submit">Send</button>
        </form>
      )}
    </Card>
  );
}

function Users({ members, me, name, nudges }) {
  const others = members.filter((m) => m.id !== me);
  return (
    <Card title="Users" tag="#server-to-user-…">
      <p className="muted">
        Each tab signs in as its name. The server can send to one user wherever they are connected, or disconnect them.
      </p>
      {nudges.map((n) => (
        <p key={n.at} className="nudge">
          👋 {n.from} nudged you at {time(n.at)}
        </p>
      ))}
      <ul className="members">
        {others.length === 0 && <li className="muted">Nobody else is here yet.</li>}
        {others.map((m) => (
          <li key={m.id} className="row spread">
            <span>{m.name ?? m.id}</span>
            <span className="row">
              <button className="ghost" onClick={() => post('/api/notify', { to: m.name ?? m.id, from: name })}>
                Nudge
              </button>
              <button className="ghost danger" onClick={() => post('/api/kick', { user: m.name ?? m.id })}>
                Disconnect
              </button>
            </span>
          </li>
        ))}
      </ul>
    </Card>
  );
}

function usePoll(url, every) {
  const [data, setData] = useState(null);
  useEffect(() => {
    let alive = true;
    const load = () =>
      fetch(url)
        .then((r) => r.json())
        .then((d) => alive && setData(d))
        .catch(() => {});
    load();
    const t = setInterval(load, every);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [url, every]);
  return data;
}

function Channels() {
  const data = usePoll('/api/channels', 3000);
  return (
    <Card title="Occupied channels" tag="GET /apps/:id/channels">
      <p className="muted">Queried from Arc's HTTP API by the Next.js server every 3 seconds.</p>
      <table>
        <tbody>
          {(data?.channels ?? []).map((c) => (
            <tr key={c.name}>
              <td>
                <code>{c.name}</code>
              </td>
              <td className="muted small">{c.users !== null ? `${c.users} users` : ''}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </Card>
  );
}

function Webhooks() {
  const data = usePoll('/api/webhooks', 2000);
  const events = data?.events ?? [];
  return (
    <Card title="Webhooks received" tag="POST /api/webhooks">
      <p className="muted">
        Arc calls this app when channels are occupied or vacated and when members come and go (vacated and removed are held 2 s
        to absorb reconnects). Signatures are verified with the server SDK.
      </p>
      <ul className="log">
        {events.length === 0 && <li className="muted">None yet.</li>}
        {events.map((e, i) => (
          <li key={i}>
            <span className="muted small">{time(e.received_at)}</span> <strong>{e.name}</strong> <code>{e.channel}</code>
            {e.user_id && <span className="muted"> {e.user_id}</span>}
          </li>
        ))}
      </ul>
    </Card>
  );
}

function Log({ log }) {
  return (
    <Card title="This tab's event log">
      <ul className="log">
        {log.map((l, i) => (
          <li key={i}>
            <span className="muted small">{time(l.at)}</span> <span className={`kind ${l.kind}`}>{l.kind}</span> {l.text}
          </li>
        ))}
      </ul>
    </Card>
  );
}
