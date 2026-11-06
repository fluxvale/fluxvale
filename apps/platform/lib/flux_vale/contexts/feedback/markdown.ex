defmodule FluxVale.Feedback.Markdown do
  @moduledoc """
  The feedback board's Markdown renderer (fluxvale/fluxvale#488): the
  ONE server-side renderer for user-generated bodies — the post page's
  description and the comments island's list (the board and roadmap
  render no bodies). Feedback is untrusted public content, so the mdex
  pipeline the blog uses runs in a stricter posture — the issue is the
  spec:

  - Raw HTML never passes through. Comrak's safe render neutralizes
    inline HTML and HTML blocks, and the ammonia pass strips what is
    left, so script tags render as nothing and never as markup.
  - Link schemes are restricted to http/https/mailto; javascript: and
    data: URLs render as inert text.
  - Rendered links carry `rel="noopener"`.
  - No images (a reversible default — tracking pixels and hostile
    imagery are an abuse surface; enable later with a ruling).
  - Single newlines hard-break (`render: [hardbreaks: true]`), so
    legacy plain-text bodies written before Markdown — including the
    seeded staging content — keep their line breaks instead of
    collapsing into walls of text.

  Rendering happens at display time, never stored: a sanitizer change
  applies to every row already in the database on its next render.
  """

  alias MDEx

  # The sanitizer posture. The extension set mirrors the blog's (tables,
  # GFM strikes/tasks/autolinks) so one mental model covers both
  # surfaces; everything below tightens what the blog trusts.
  @options [
    extension: [table: true, strikethrough: true, tasklist: true, autolink: true],
    render: [hardbreaks: true],
    sanitize: [
      # The issue's allowlist — deliberately narrower than ammonia's
      # default scheme set (which admits tel:, ftp:, sms:, …). A link
      # whose scheme is not listed renders with its href stripped.
      url_schemes: ["http", "https", "mailto"],
      # No images: tracking pixels and hostile imagery are an abuse
      # surface (reversible — a ruling can lift this).
      rm_tags: ["img"],
      # Tabnabbing protection on every rendered link.
      link_rel: "noopener"
    ]
  ]

  @doc """
  Renders an untrusted Markdown body to sanitized HTML. The result is
  safe for `raw/1` — the hostile input classes are pinned inert by
  MarkdownTest, and each pin fails if its layer regresses.
  """
  @spec render(String.t()) :: String.t()
  def render(markdown) when is_binary(markdown) do
    MDEx.to_html!(markdown, @options)
  end
end
