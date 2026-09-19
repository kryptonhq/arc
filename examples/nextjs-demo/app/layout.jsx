import './globals.css';

export const metadata = {
  title: 'Arc demo',
  description: 'Realtime channels, presence, client events, encryption, cache channels and webhooks on a local Arc.',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
