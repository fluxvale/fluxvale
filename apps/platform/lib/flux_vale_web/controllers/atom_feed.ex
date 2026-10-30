defmodule FluxValeWeb.AtomFeed do
  @moduledoc """
  `/blog/feed` document builder (ADR-00025 §1 + Am. 1): Atom 1.0 over
  the published posts, newest first, full content in each entry.

  Deliberately NOT a `.heex` template, same as `FluxValeWeb.SitemapXML`
  (see `FluxValeWeb.XML` for why): plain XML building keeps the feed
  parser-clean. URLs are the canonical prod origin always (staging
  serves prod URLs by design, ADR-00025). Drafts never appear — the
  feed mirrors exactly what the prod sitemap advertises.
  """

  alias FluxVale.Blog.Post
  alias FluxValeWeb.Seo
  alias FluxValeWeb.XML

  @atom_ns "http://www.w3.org/2005/Atom"
  # The self-consistent cap: a young blog ships every post; a feed that
  # ever grows past this wants a real truncation decision made then.
  @max_entries 20

  @doc """
  Builds the Atom feed for the published posts (already newest-first).
  """
  @spec build([Post.t()]) :: iodata()
  def build(posts) do
    entries = Enum.take(posts, @max_entries)
    feed_updated = updated(entries)

    [
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<feed xmlns="#{@atom_ns}">),
      "<title>",
      XML.escape("FluxVale Blog"),
      "</title>",
      "<id>",
      XML.escape(feed_url()),
      "</id>",
      "<link rel=\"self\" href=\"",
      XML.escape(feed_url()),
      "\"/>",
      "<link rel=\"alternate\" href=\"",
      XML.escape(blog_url()),
      "\"/>",
      "<updated>",
      XML.escape(feed_updated),
      "</updated>",
      for post <- entries do
        entry(post)
      end,
      "</feed>"
    ]
  end

  defp entry(post) do
    url = post_url(post)
    title = XML.escape(post.title)
    author = XML.escape(post.author)
    description = XML.escape(post.description)
    html = XML.escape(post.html)
    iso_date = Date.to_iso8601(post.date)
    published = XML.escape(iso_date)

    [
      "<entry>",
      "<title>",
      title,
      "</title>",
      "<id>",
      XML.escape(url),
      "</id>",
      "<link href=\"",
      XML.escape(url),
      "\"/>",
      "<published>",
      published,
      "</published>",
      "<updated>",
      published,
      "</updated>",
      "<author><name>",
      author,
      "</name></author>",
      "<summary type=\"text\">",
      description,
      "</summary>",
      "<content type=\"html\">",
      html,
      "</content>",
      "</entry>"
    ]
  end

  # Feed validity for the empty state: Atom requires <updated>; the
  # epoch is the honest "nothing has ever published" timestamp.
  defp updated([%Post{date: date} | _rest]) do
    datetime = to_utc_datetime(date)
    DateTime.to_iso8601(datetime)
  end

  defp updated([]) do
    datetime = to_utc_datetime(~D[1970-01-01])
    DateTime.to_iso8601(datetime)
  end

  defp to_utc_datetime(%Date{} = date) do
    {:ok, datetime} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    datetime
  end

  defp feed_url, do: Seo.canonical_origin() <> "/blog/feed"
  defp blog_url, do: Seo.canonical_origin() <> "/blog"
  defp post_url(%Post{} = post), do: Seo.canonical_origin() <> "/blog/#{post.slug}"
end
