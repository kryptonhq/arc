'use client';

import { useEffect, useId, useState } from 'react';
import { useTheme } from 'next-themes';

/**
 * Renders a Mermaid diagram.
 *
 * Mermaid draws in the browser, so the diagram is rendered after mount and
 * re-rendered when the colour scheme changes. Diagrams come from this repository's
 * own MDX, never from user input, and Mermaid is initialised with its strict
 * security level, which sanitises the SVG it produces.
 */
export function Mermaid({ chart }: { chart: string }) {
  const id = useId().replace(/:/g, '');
  const { resolvedTheme } = useTheme();
  const [svg, setSvg] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    void (async () => {
      const { default: mermaid } = await import('mermaid');
      const dark = resolvedTheme === 'dark';

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        fontFamily: 'var(--font-sans), sans-serif',
        theme: 'base',
        themeVariables: {
          // Arc's palette, so diagrams sit in the page rather than on top of it.
          background: 'transparent',
          primaryColor: dark ? '#1d2c39' : '#eef1ff',
          primaryBorderColor: dark ? '#4f6a8a' : '#2a4be0',
          primaryTextColor: dark ? '#e7ecf2' : '#14202b',
          lineColor: dark ? '#7a8895' : '#5b6b7a',
          secondaryColor: dark ? '#14202b' : '#d7f2ec',
          tertiaryColor: dark ? '#0d1720' : '#f5f6f8',
          actorBkg: dark ? '#1d2c39' : '#eef1ff',
          actorBorder: '#2a4be0',
          actorTextColor: dark ? '#e7ecf2' : '#14202b',
          signalColor: dark ? '#a3aeb9' : '#2b3d4d',
          signalTextColor: dark ? '#a3aeb9' : '#2b3d4d',
          noteBkgColor: dark ? '#14202b' : '#fdf6e8',
          noteTextColor: dark ? '#e7ecf2' : '#8a5300',
          noteBorderColor: dark ? '#2b3d4d' : '#e2b872',
        },
      });

      const { svg } = await mermaid.render(`mermaid-${id}`, chart.trim());
      if (active) setSvg(svg);
    })();

    return () => {
      active = false;
    };
  }, [chart, id, resolvedTheme]);

  return (
    <figure className="my-6 overflow-x-auto rounded-lg border border-fd-border bg-fd-card p-4 [&_svg]:mx-auto [&_svg]:h-auto [&_svg]:max-w-full">
      {svg ? (
        <div dangerouslySetInnerHTML={{ __html: svg }} />
      ) : (
        <p className="py-6 text-center text-sm text-fd-muted-foreground">Drawing diagram…</p>
      )}
    </figure>
  );
}
