# Arc documentation site

The documentation at `/docs`, built with [Fumadocs](https://fumadocs.dev) on Next.js.
It is a separate app from the Arc server, so it deploys and upgrades on its own.

```bash
npm install
npm run dev     # http://localhost:3000
npm run build   # what CI and Vercel run
```

## Where things are

| Path | What it holds |
| --- | --- |
| `content/docs/**.mdx` | The pages. The folder structure is the URL structure |
| `content/docs/**/meta.json` | Section titles, icons, and page order |
| `lib/shared.ts` | Site name and the GitHub repository the "Edit on GitHub" links point at |
| `lib/layout.shared.tsx` | Navigation bar: wordmark and top-level links |
| `app/(home)/page.tsx` | The landing page |
| `app/global.css` | Arc's palette and typefaces, matching the dashboard |
| `components/mdx.tsx` | Components usable in MDX (`Callout`, `Cards`, `Steps`, `Tabs`) |

Adding a page means adding an `.mdx` file with `title` and `description` frontmatter,
then listing it in the folder's `meta.json`. Search, `llms.txt` and OG images pick it up
automatically.

Write links between pages as relative paths (`/docs/protocol/channels`), and plain URLs
as Markdown links: MDX reads `<https://example.com>` as JSX and the build fails.

## Deploying to Vercel

Import the repository and set:

| Setting | Value |
| --- | --- |
| Root directory | `website` |
| Framework preset | Next.js (detected) |
| Build command | `npm run build` (default) |

No environment variables are needed. To serve the docs under the product domain, point
`docs.example.com` at this project, or route `/docs/*` to it from the main site with
Next.js Multi-Zones — the docs stay under `/docs` so either works.
