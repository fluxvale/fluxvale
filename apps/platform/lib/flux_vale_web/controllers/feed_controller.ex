defmodule FluxValeWeb.FeedController do
  @moduledoc """
  The blog's feed routes (ADR-00025 §1 + Am. 1): Atom at `/blog/feed`
  and the ADR's original `/feed.xml` as a permanent 301. Both are
  pipeline-less (see the router) — any client gets them regardless of
  its Accept header; the feed action sets the Atom content type itself.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Blog
  alias FluxValeWeb.AtomFeed
  alias FluxValeWeb.Seo

  def show(conn, _params) do
    Blog.maybe_hot_reload()

    conn
    |> put_resp_content_type("application/atom+xml")
    |> send_resp(200, AtomFeed.build(Blog.published()))
  end

  # Am. 1: /feed.xml was ADR-00025 §3's URL; it now points at the
  # canonical feed. Absolute to the canonical origin — staging serves
  # prod URLs by design, and feed readers follow absolute redirects.
  # put_status first: redirect/2 itself always sends 302 (conn.status
  # || 302 — no :status option).
  def legacy(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(external: Seo.canonical_origin() <> "/blog/feed")
  end
end
