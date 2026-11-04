defmodule FluxValeWeb.FeedbackController do
  @moduledoc """
  The public feedback board's SSR surface (fluxvale/fluxvale#412,
  [ADR-0026](../../../../../docs/adr/00026-feedback-board.md) §4): `/feedback`
  board, `/feedback/:slug` post pages, and `/roadmap` (T9) — plain
  controller+HEEx, never LiveView, so crawlers get the full document
  with zero JS (the blog/catalog pattern). Reads ride the public read
  policy (`actor: nil`, the catalog posture); this slice is deliberately
  read-only — no vote button, no comment form, no composer. The
  interactive layer mounts on these same pages in a later slice.

  Board view state rides query params (sort, status filter, page), so
  the canonical URL stays the bare `/feedback` for every view.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Feedback.Post

  # The filter DSL is a macro (the sanctioned require, as in Seeds).
  require Ash.Query

  @page_size 20
  # The offset arithmetic rides Postgrex's int8 bind: a huge page number
  # (a 19-digit ?page= parses fine as an integer) overflows the multiply
  # and 500s the board. No board needs page 10,000 — clamp and keep the
  # deep ranges answering 200 with an empty window.
  @max_page 10_000
  @sorts ["top", "new"]
  @board_description "Feature requests and bug reports from the FluxVale community"
  @description_chars 160

  # The roadmap's columns (T9): the three forward-looking statuses. Open
  # is the untriaged backlog (the board's job), declined is the "no",
  # duplicates fold into their originals' presence — none of them are
  # roadmap states.
  @roadmap_statuses [:planned, :started, :completed]
  @roadmap_description "What FluxVale is building next, and what has shipped"

  def index(conn, params) do
    sort = sort(params)
    status = status_filter(params)

    page =
      params
      |> page_number()
      |> min(@max_page)

    filtered =
      Post
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> status_scope(status)

    total = Ash.count!(filtered, actor: nil)

    # Offset pagination over the sorted window — the board is small this
    # slice (page size 20); keyset can come when it earns its keep.
    posts =
      filtered
      |> Ash.Query.sort(sort_order(sort))
      |> Ash.Query.offset((page - 1) * @page_size)
      |> Ash.Query.limit(@page_size)
      |> Ash.read!(actor: nil)

    conn
    |> assign(:page_title, "Feedback · FluxVale")
    |> assign(:page_description, @board_description)
    |> assign(:canonical_path, "/feedback")
    |> assign(:posts, posts)
    |> assign(:sort, sort)
    |> assign(:status, status)
    |> assign(:page, page)
    |> assign(:total_pages, max(page_count(total), 1))
    |> render(:index)
  end

  # The roadmap (T9): a VIEW over post statuses, no new domain
  # machinery. One read feeds all three columns.
  def roadmap(conn, _params) do
    columns =
      Post
      |> Ash.Query.for_read(:read, %{}, actor: nil)
      |> Ash.Query.filter(status in @roadmap_statuses)
      # Unbounded read, conscious acceptance: the roadmap shows only the
      # three forward-looking statuses, but they are user-generated rows.
      # Revisit at growth (per-column pagination or a display cap), the
      # sitemap's marker posture.
      |> Ash.read!(actor: nil)
      |> roadmap_columns()

    conn
    |> assign(:page_title, "Roadmap · FluxVale")
    |> assign(:page_description, @roadmap_description)
    |> assign(:canonical_path, "/roadmap")
    |> assign(:columns, columns)
    |> render(:roadmap)
  end

  def show(conn, %{"slug" => slug}) do
    case by_slug(slug) do
      {:ok, %Post{} = post} ->
        render_post(conn, post)

      # Unknown slugs read as "not here" — a real 404 (the catalog rule:
      # public pages get linked and crawled; a 302 would lie).
      _missing ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: FluxValeWeb.Router
    end
  end

  # The roadmap's per-column ordering rule (T9): Planned reads in DEMAND
  # order — vote_count DESC with created_at DESC breaking ties (the
  # board's "top" rule, so the column signals momentum). Started and
  # Completed read freshest-first — status_changed_at DESC (it doubles
  # as the completed-when date). The orders differ per column, so the
  # sort happens here, not in the SQL.
  defp roadmap_columns(posts) do
    by_status = Enum.group_by(posts, & &1.status)

    [
      %{status: :planned, posts: sort_by_votes(by_status[:planned] || [])},
      %{status: :started, posts: sort_by_recency(by_status[:started] || [])},
      %{status: :completed, posts: sort_by_recency(by_status[:completed] || [])}
    ]
  end

  defp sort_by_votes(planned) do
    # A plain comparator: vote_count wins, the fresher post breaks ties.
    # (The {:desc, :desc} tuple-of-shorthands is not a valid Enum.sort_by
    # sorter — bare atoms inside a tuple are read as compare modules.)
    # Full ties keep NO guaranteed order — Enum.sort with a comparator
    # is not stable — so nothing may rely on tie order.
    Enum.sort(planned, fn left, right ->
      if left.vote_count != right.vote_count do
        left.vote_count > right.vote_count
      else
        DateTime.compare(left.created_at, right.created_at) == :gt
      end
    end)
  end

  # A post reaches the roadmap only through :set_status, which always
  # stamps status_changed_at — the coalesce just keeps a stamp-less row
  # (seeds force timestamps the actions do not accept) from crashing the
  # DateTime compare, falling back to the created age.
  defp sort_by_recency(posts) do
    Enum.sort_by(posts, &(&1.status_changed_at || &1.created_at), {:desc, DateTime})
  end

  # The default view is every status EXCEPT duplicates (the folded
  # posts have their own chip); a known status param narrows to it.
  # Unknown params fall back to the default view, never an error.
  defp status_scope(query, nil), do: Ash.Query.filter(query, status != :duplicate)
  defp status_scope(query, status), do: Ash.Query.filter(query, status == ^status)

  # top: votes win, then fresher first on ties (the DEFAULT view).
  # new: pure recency.
  defp sort_order("new"), do: [created_at: :desc]
  defp sort_order(_top), do: [vote_count: :desc, created_at: :desc]

  defp sort(%{"sort" => sort}) when sort in @sorts, do: sort
  defp sort(_params), do: "top"

  # Declared atoms only — the list comes from the resource (the single
  # source the HTML module derives from too), and the declared list is
  # matched by string, so no input path ever builds an atom dynamically
  # (the resource's own rule).
  defp status_filter(%{"status" => raw}) when is_binary(raw) do
    Enum.find(Post.status_values(), fn status -> Atom.to_string(status) == raw end)
  end

  defp status_filter(_params), do: nil

  defp page_number(%{"page" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {page, ""} when page >= 1 -> page
      _garbage -> 1
    end
  end

  # A list/map-shaped param (repeated or indexed query key) is not a
  # page number either.
  defp page_number(_params), do: 1

  defp page_count(total), do: div(total + @page_size - 1, @page_size)

  defp by_slug(slug) do
    Post
    |> Ash.Query.for_read(:read, %{}, actor: nil)
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read_one(actor: nil)
  end

  defp render_post(conn, post) do
    # The merged-into banner is the only relationship this page renders:
    # a duplicate loads its original (title + slug). The organization is
    # NOT loaded — Organization reads are members-only (its read policy),
    # so there is no public attribution shape this slice could render.
    post =
      if post.status == :duplicate do
        Ash.load!(post, :duplicate_of, actor: nil)
      else
        post
      end

    conn
    |> assign(:page_title, "#{post.title} - #{post.vote_count} votes - FluxVale")
    |> assign(:page_description, meta_description(post.description))
    |> assign(:canonical_path, "/feedback/#{post.slug}")
    |> assign(:post, post)
    |> render(:show)
  end

  # The body is plain text (max 5000); the meta description is its head
  # cut at a word boundary near 160 chars.
  defp meta_description(body) do
    if String.length(body) <= @description_chars do
      body
    else
      head = String.slice(body, 0, @description_chars)
      words = String.split(head, " ")

      trimmed =
        if length(words) == 1 do
          head
        else
          kept = Enum.take(words, length(words) - 1)
          Enum.join(kept, " ")
        end

      trimmed <> "…"
    end
  end
end
