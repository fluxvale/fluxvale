---
title: Example post
description: A short example showing how posts on this blog are written — replace it with the first real post.
date: 2026-10-31
slug: example-post
author: FluxVale
---

This is an example post. It exists so the blog has something to render
and so the authoring format is documented in the place it will be used.
Replace this file (or delete it) when the first real post is ready —
nothing else references it.

Posts are markdown files in `apps/platform/priv/content/blog/`, one
file per post. The filename must equal the post's `slug` plus `.md`.

## Frontmatter

Every post opens with a YAML block:

```yaml
---
title: Example post          # required — the page title
description: What the post
  is about, in one line      # required — the search-result summary
date: 2026-10-31             # required — publish date (YYYY-MM-DD)
slug: example-post           # required — must equal the filename stem
author: FluxVale             # required — the byline
draft: false                 # optional — see below
og_image: /images/og-default.png  # optional — falls back to og-default.png
tags: [example]              # optional — parsed, not shown yet
---
```

| Field | Required | Default |
|---|---|---|
| title | yes | — |
| description | yes | — |
| date | yes | — |
| slug | yes | — |
| author | yes | — |
| draft | no | `false` |
| og_image | no | `/images/og-default.png` |
| tags | no | none |

## Drafts

Set `draft: true` to keep a post out of production. Drafts:

- are excluded from the sitemap and the Atom feed everywhere
- render on staging and review environments, for previewing
- return 404 on the production host

So the workflow is: write, open a PR, preview the draft on the review
environment, merge when happy. A merge deploys and publishes.

## Checking a post

`mix blog.lint` validates the content directory — frontmatter present
and well-formed, required fields filled, slugs unique and matching
their filenames. CI runs it on every PR, so a malformed post fails the
build instead of shipping.

Reading time is computed automatically; headings, lists, tables, code
blocks, blockquotes and links work as elsewhere in markdown.

> This post is deliberately plain — no product pitch lives here. Write
> the real first post in your own voice and remove this one.
