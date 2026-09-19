import Demo from '@/components/Demo';
import { clientConfig } from '@/lib/arc';

// Credentials are read at request time (the compose stack writes them on boot).
export const dynamic = 'force-dynamic';

export default function Page() {
  let config;
  try {
    config = clientConfig();
  } catch (error) {
    return (
      <main className="shell">
        <div className="card">
          <h1>Arc demo</h1>
          <p className="muted">{error.message}</p>
          <p className="muted">
            Run the full stack with <code>docker compose up</code>, or see <code>examples/nextjs-demo/README.md</code>.
          </p>
        </div>
      </main>
    );
  }
  return <Demo config={config} />;
}
