defmodule FluxValeWeb.Seo do
  @moduledoc """
  SEO head tags (#164, ADR-00025 §3+4): description, canonical link,
  Open Graph and Twitter cards, plus the noindex meta for non-prod hosts.
  Rendered from the root layout, so every page gets it.

  Canonicals (and og/twitter URLs) always point at the canonical prod
  origin regardless of the serving host — staging serves prod URLs by
  design (ADR-00025).
  """

  use FluxValeWeb, :html

  @site_name "FluxVale"
  @default_title "Managed hosting for open source apps"
  @default_description @default_title
  @og_image_path "/images/og-default.png"

  # compile_env is module-body-only — baked at compile time, like the
  # noindex plug's host (the canonical identity is static config).
  @canonical_origin Application.compile_env(:flux_vale, :canonical_origin, "https://fluxvale.com")

  @doc """
  The canonical prod origin — the single SEO URL prefix. Reads config;
  never hardcode the origin elsewhere.
  """
  @spec canonical_origin() :: String.t()
  def canonical_origin, do: @canonical_origin

  @doc """
  The fallback OG image path — every surface without a per-page image
  (per-post `og_image` frontmatter resolves against this, ADR-00025 §1).
  """
  @spec default_og_image_path() :: String.t()
  def default_og_image_path, do: @og_image_path

  @doc """
  Head tags for every page. Every assign is optional — `nil` falls back
  to the site default. HEEx components receive only the attributes
  they're given, so the root layout forwards these from the conn
  explicitly; `:robots_noindex` arrives from `FluxValeWeb.Plugs.SeoNoindex`.
  Controller pages carry it through assigns; LiveViews render the root
  layout from the conn on first paint (so the meta lands there too) and
  ride the X-Robots-Tag header afterwards — both signals agree.

  Title convention (#164): controllers set the FULL branded title
  ("App catalog · FluxVale") — the root layout's live_title has no
  suffix, so og:title rides the value through untouched. The nil
  default (landing) gets the brand appended to the plain description.
  Blog posts (ADR-00025 §1) add three optional assigns: `:og_image_path`
  (an app-absolute path overriding the default OG image), `:og_type`
  ("article" on posts; "website" is the default), and
  `:article_published_time` (the ISO publish date, emitted as og
  article metadata).
  """
  @spec seo_tags(map()) :: Phoenix.LiveView.Rendered.t()
  def seo_tags(assigns) do
    # Components receive only given attrs — a missing key is the default
    # path. Bind everything before the one assign (HEEx reads assigns,
    # never module attributes; see apps/platform/AGENTS.md on the pipe
    # checks).
    page_title = assigns[:page_title]
    description = assigns[:page_description] || @default_description
    canonical_path = assigns[:canonical_path]
    robots_noindex = assigns[:robots_noindex] || false
    og_image_path = assigns[:og_image_path] || @og_image_path
    og_type = assigns[:og_type] || "website"
    article_published_time = assigns[:article_published_time]

    assigns =
      assign(assigns,
        page_title: page_title,
        description: description,
        canonical_path: canonical_path,
        robots_noindex: robots_noindex,
        og_type: og_type,
        article_published_time: article_published_time,
        site_name: @site_name,
        og_title: og_title(page_title),
        og_image_url: @canonical_origin <> og_image_path
      )

    ~H"""
    <meta name="description" content={@description} />
    <meta :if={@robots_noindex} name="robots" content="noindex, nofollow" />
    <%!-- og:url is a canonical signal — emitted only with a canonical path,
    like the link tag above. --%>
    <link :if={@canonical_path} rel="canonical" href={canonical_origin() <> @canonical_path} />
    <meta property="og:title" content={@og_title} />
    <meta property="og:description" content={@description} />
    <meta property="og:type" content={@og_type} />
    <meta
      :if={@article_published_time}
      property="article:published_time"
      content={@article_published_time}
    />
    <meta :if={@canonical_path} property="og:url" content={canonical_origin() <> @canonical_path} />
    <meta property="og:site_name" content={@site_name} />
    <meta property="og:image" content={@og_image_url} />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content={@og_title} />
    <meta name="twitter:description" content={@description} />
    <meta name="twitter:image" content={@og_image_url} />
    """
  end

  # Branded titles pass through; the plain-description default gets the
  # brand appended.
  defp og_title(nil), do: "#{@default_title} · #{@site_name}"
  defp og_title(page_title), do: page_title
end
