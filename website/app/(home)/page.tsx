import Link from 'next/link';

const channelTypes = [
  { prefix: 'public', note: 'anyone may subscribe' },
  { prefix: 'private-', note: 'your backend authorises' },
  { prefix: 'presence-', note: 'who is here, by user' },
  { prefix: 'private-encrypted-', note: 'the server relays ciphertext' },
  { prefix: 'cache-', note: 'last event replayed on subscribe' },
];

export default function HomePage() {
  return (
    <main className="flex flex-1 flex-col">
      <section className="mx-auto w-full max-w-5xl px-6 pb-16 pt-20">
        <p className="inline-flex items-center gap-2 rounded-full border border-fd-border px-3 py-1 text-xs text-fd-muted-foreground">
          <span className="size-1.5 rounded-full bg-[var(--color-arc-live)]" />
          Channels protocol v7, self-hosted
        </p>

        <h1 className="mt-6 max-w-3xl text-4xl font-semibold leading-tight tracking-tight sm:text-5xl">
          Realtime messaging you run yourself.
        </h1>

        <p className="mt-5 max-w-2xl text-lg text-fd-muted-foreground">
          Arc holds the WebSocket connections, groups them into channels, tracks who is
          present, and gives your backend a signed HTTP API to publish to them. Existing
          client and server SDKs work against it by changing the host and credentials.
        </p>

        <div className="mt-8 flex flex-wrap items-center gap-3">
          <Link
            href="/docs/getting-started"
            className="rounded-md bg-fd-primary px-4 py-2 text-sm font-medium text-fd-primary-foreground transition-colors hover:opacity-90"
          >
            Run it locally
          </Link>
          <Link
            href="/docs"
            className="rounded-md border border-fd-border px-4 py-2 text-sm font-medium transition-colors hover:bg-fd-accent"
          >
            Read the docs
          </Link>
        </div>

        <pre className="mt-10 w-fit max-w-full overflow-x-auto rounded-lg border border-fd-border bg-fd-card px-4 py-3 font-mono text-sm">
          <code>docker run -p 4000:4000 kryptonhq/arc:latest</code>
        </pre>
      </section>

      <section className="border-t border-fd-border bg-fd-card/40">
        <div className="mx-auto grid w-full max-w-5xl gap-px overflow-hidden px-6 py-12 sm:grid-cols-3">
          <Feature
            title="Every channel type on day one"
            body="Public, private, presence, end-to-end encrypted and cache channels, plus a channel per signed-in user."
          />
          <Feature
            title="Presence that doesn't drift"
            body="Members are counted per user, not per connection, and converge across nodes after a partition."
          />
          <Feature
            title="Webhooks that don't flap"
            body="Occupancy events are held briefly, so a reconnecting client produces no traffic at all."
          />
        </div>
      </section>

      <section className="mx-auto w-full max-w-5xl px-6 py-14">
        <h2 className="text-lg font-semibold tracking-tight">Channels by prefix</h2>
        <p className="mt-1 text-sm text-fd-muted-foreground">
          A channel is a name. Its prefix decides what it allows.
        </p>
        <ul className="mt-5 divide-y divide-fd-border border-y border-fd-border">
          {channelTypes.map((channel) => (
            <li key={channel.prefix} className="flex flex-wrap items-baseline gap-x-4 py-2.5">
              <code className="font-mono text-sm">{channel.prefix}</code>
              <span className="text-sm text-fd-muted-foreground">{channel.note}</span>
            </li>
          ))}
        </ul>
        <Link
          href="/docs/protocol/channels"
          className="mt-5 inline-block text-sm font-medium text-fd-primary hover:underline"
        >
          How channels work
        </Link>
      </section>
    </main>
  );
}

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div className="px-1 py-4 sm:px-6 sm:py-0">
      <h2 className="text-sm font-semibold">{title}</h2>
      <p className="mt-1.5 text-sm text-fd-muted-foreground">{body}</p>
    </div>
  );
}
