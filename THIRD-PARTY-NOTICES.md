# Third-party notices

Arc is licensed under the Apache License 2.0 (see [LICENSE](LICENSE)). It uses the
components below. This file lists the ones whose licences ask for a notice when their
work is redistributed, which happens when you run an Arc release or deploy the
documentation site.

Licences were read from the packages themselves, not from memory. To reproduce the
inventory: `mix deps.get` then read `deps/*/hex_metadata.config`, and
`npm ci && npx license-checker-rspack --summary` in `website/` and
`examples/nextjs-demo/`.

## Shipped in the Arc server image

| Component | Licence | Why it is here |
| --- | --- | --- |
| Elixir, Erlang/OTP | Apache-2.0 | Runtime |
| Phoenix, Plug, Bandit, Ecto, Postgrex and the rest of the Elixir dependencies | MIT or Apache-2.0 | 61 packages, all permissive |
| [Heroicons](https://github.com/tailwindlabs/heroicons) v2.2.0 | MIT | Icons in the dashboard. The build inlines the SVGs into `app.css`, so the artwork is redistributed |
| [topbar](http://buunguyen.github.io/topbar) 3.0.0 | MIT | Page-load indicator, vendored at `assets/vendor/topbar.js` |

### Heroicons

```
MIT License — Copyright (c) 2020 Refactoring UI Inc.
https://github.com/tailwindlabs/heroicons/blob/master/LICENSE
```

Arc fetches Heroicons with a sparse checkout that omits the licence file, so it is
reproduced here.

### topbar

```
MIT License — Copyright (c) 2024 Buu Nguyen
```

The notice is kept in the vendored file's header.

## Shipped in the documentation site

| Component | Licence | Note |
| --- | --- | --- |
| Next.js, React, Fumadocs, Tailwind CSS, Mermaid and their dependencies | MIT, ISC, Apache-2.0, BSD | 388 packages, permissive |
| [IBM Plex Sans and IBM Plex Mono](https://github.com/IBM/plex) | OFL-1.1 | `next/font` self-hosts the font files in the build output, so the fonts are redistributed |
| [elkjs](https://github.com/kieler/elkjs) | EPL-2.0 | A Mermaid layout dependency that ends up in the client bundle |
| [lucide-react](https://lucide.dev) | ISC | Icons in the documentation navigation |

### IBM Plex

```
Copyright © 2017 IBM Corp. Licensed under the SIL Open Font License, Version 1.1.
https://github.com/IBM/plex/blob/master/LICENSE.txt
```

"IBM Plex" is a Reserved Font Name under the OFL: a modified version of the fonts may
not carry that name.

### elkjs

Licensed under the Eclipse Public License 2.0. Source:
<https://github.com/kieler/elkjs>. Arc ships it unmodified, as a dependency of Mermaid.

## Present but not redistributed by Arc

| Component | Licence | Note |
| --- | --- | --- |
| `sharp` / `libvips` (`@img/sharp-*`) | Apache-2.0 / **LGPL-3.0-or-later** | An optional Next.js dependency for image optimisation. It is installed during a build and runs server-side; it is not bundled into the pages Arc serves. Packaging the documentation site as a container image would redistribute the LGPL binaries, which brings its own obligations: ship the licence and allow the library to be replaced |
| `pusher-js`, `pusher` (npm), `pusher` (PyPI) | MIT | The client and server SDKs Arc is tested against. They are development and example dependencies; the Arc server does not contain them |

## Compatibility and names

Arc is an independent implementation of the realtime wire protocol (version 7) that the
above client and server SDKs speak. Arc is not affiliated with, endorsed by, or
sponsored by the authors or owners of those SDKs or of the service they were written
for. Product names, logos and trademarks mentioned anywhere in this repository belong
to their respective owners, and are used only to say what Arc interoperates with.

Protocol identifiers that appear on the wire — event names such as
`pusher:connection_established`, and headers such as `X-Pusher-Signature` — are fixed
by the protocol. They are present because a client that speaks it will send and expect
exactly those bytes, not as a claim of association.
