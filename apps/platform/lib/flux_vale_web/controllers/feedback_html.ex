defmodule FluxValeWeb.FeedbackHTML do
  @moduledoc """
  Templates and display helpers for the public feedback board
  (fluxvale/fluxvale#412, [ADR-0026](../../../../../docs/adr/00026-feedback-board.md)).
  """

  use FluxValeWeb, :html

  alias FluxVale.Feedback.Post

  embed_templates("feedback_html/*")

  # The status vocabulary derives from the resource's declared list (the
  # single source — the controller's filter reads it too), so a new
  # status shows up as a chip without this module being edited. The
  # label/tone maps below are the display contract: FeedbackHTMLTest
  # iterates the resource's list against them, so adding a status
  # without a label + tone fails the suite instead of 500ing the board.
  @status_labels %{
    open: "Open",
    planned: "Planned",
    started: "Started",
    completed: "Completed",
    duplicate: "Duplicate",
    declined: "Declined"
  }

  # Badge tones ride the design system's semantic color pairs, so the
  # badge renders consistently in both modes. Open stays quiet (every
  # fresh post wears it), duplicate folds away neutral, declined reads
  # as the "no".
  @status_tones %{
    open: "neutral",
    planned: "primary",
    started: "warning",
    completed: "success",
    duplicate: "neutral",
    declined: "danger"
  }

  @doc "The filter chips' status list (order is the render order)."
  def status_options, do: Post.status_values()

  @doc "User-facing label for a post status."
  def status_label(status), do: Map.fetch!(@status_labels, status)

  @doc "Badge tone for a post status (see the tone map's comment)."
  def status_tone(status), do: Map.fetch!(@status_tones, status)

  @doc """
  The roadmap column's heading label (T9). Gettext'd msgids ARE the
  source of truth here, so this map is deliberately its own three
  clauses instead of reusing status_label/1 (a dynamic msgid would
  vanish from the extraction).
  """
  def roadmap_column_label(:planned), do: gettext("Planned")
  def roadmap_column_label(:started), do: gettext("Started")
  def roadmap_column_label(:completed), do: gettext("Completed")

  @doc """
  The roadmap's honest empty-column copy (T9): one plain sentence per
  column, true of that column alone.
  """
  def empty_column_copy(:planned), do: gettext("Nothing planned yet.")
  def empty_column_copy(:started), do: gettext("Nothing underway yet.")
  def empty_column_copy(:completed), do: gettext("Nothing shipped yet.")

  @doc """
  The post's tags whose slug matches a catalog app — the cross-link set
  (T10's display convention). The controller passes the catalog's
  matching slugs; this filter keeps the template declarative.
  """
  def app_linked_tags(tags, app_slugs) do
    Enum.filter(tags, &MapSet.member?(app_slugs, &1.slug))
  end

  @doc """
  Whether the board's tag filter sits on this chip (the aria-current and
  toggle-off state). The nil-safe active check the template's class list
  rides.
  """
  def tag_chip_active?(_tag, nil), do: false

  def tag_chip_active?(tag, active_tag), do: tag.slug == active_tag.slug

  @doc """
  Renders the board's status badge.
  """
  attr(:status, :atom, required: true)

  def feedback_status_badge(assigns) do
    assigns =
      assign(assigns,
        label: status_label(assigns.status),
        tone: status_tone(assigns.status)
      )

    ~H"""
    <.badge tone={@tone} data-testid="feedback-status">{@label}</.badge>
    """
  end

  @doc """
  The board/roadmap view tabs (#412 T9) — the header link pair both
  public feedback surfaces render (the board page's header shape: the
  `.header` actions slot, styled like its sort tabs). `:current` marks
  the page showing it.
  """
  attr(:current, :atom, required: true, values: [:board, :roadmap])

  def lane_tabs(assigns) do
    assigns = assign(assigns, :roadmap_current, assigns.current == :roadmap)

    ~H"""
    <nav
      aria-label={gettext("Feedback views")}
      class="flex items-center gap-1 rounded-control border border-line bg-panel p-1 text-sm"
    >
      <.link
        href={~p"/feedback"}
        aria-current={not @roadmap_current && "page"}
        class={[
          "rounded-[calc(var(--radius-control)-0.25rem)] px-3 py-1.5 font-medium transition-colors duration-(--motion-fast)",
          not @roadmap_current && "bg-primary-muted text-link",
          @roadmap_current && "text-ink-muted hover:text-ink"
        ]}
      >
        {gettext("Board")}
      </.link>
      <.link
        href={~p"/roadmap"}
        data-testid="roadmap-link"
        aria-current={@roadmap_current && "page"}
        class={[
          "rounded-[calc(var(--radius-control)-0.25rem)] px-3 py-1.5 font-medium transition-colors duration-(--motion-fast)",
          @roadmap_current && "bg-primary-muted text-link",
          not @roadmap_current && "text-ink-muted hover:text-ink"
        ]}
      >
        {gettext("Roadmap")}
      </.link>
    </nav>
    """
  end

  @doc """
  Renders a post's tag chip. Display only: board rows are one big link,
  and nested anchors are invalid HTML — the chips stay plain there and
  link only on the post page (feedback_tag_link).
  """
  attr(:tag, FluxVale.Feedback.Tag, required: true)

  def feedback_tag_chip(assigns) do
    ~H"""
    <span
      data-testid="feedback-tag"
      class="rounded-full border border-line bg-panel px-2 py-0.5 text-xs font-medium text-ink-muted"
    >
      {@tag.name}
    </span>
    """
  end

  @doc """
  Renders a post page's tag chip: a link to the board filtered by the
  tag (the default view, page one).
  """
  attr(:tag, FluxVale.Feedback.Tag, required: true)

  def feedback_tag_link(assigns) do
    ~H"""
    <.link
      href={board_href("top", nil, 1, @tag.slug)}
      data-testid="feedback-tag-link"
      class="rounded-full border border-line bg-panel px-2.5 py-1 text-xs font-medium text-ink-muted transition-colors duration-(--motion-fast) hover:border-line-strong hover:text-ink"
    >
      {@tag.name}
    </.link>
    """
  end

  @doc """
  Renders the catalog cross-link (T10's display convention): a tag
  whose slug matches a catalog app's slug links the app's /apps/:slug
  page. The controller passes only matching slugs in @app_slugs.
  """
  attr(:tag, FluxVale.Feedback.Tag, required: true)

  def feedback_app_link(assigns) do
    ~H"""
    <.link
      href={~p"/apps/#{@tag.slug}"}
      data-testid="feedback-app-link"
      class="inline-flex items-center gap-1 text-sm font-medium text-link transition-colors duration-(--motion-fast) hover:underline"
    >
      <.icon name="hero-arrow-top-right-on-square" class="size-4" />
      {gettext("%{name} in the app catalog", name: @tag.name)}
    </.link>
    """
  end

  @doc """
  The post's status line: the label plus when it last moved
  ("Started 2 days ago"). A post born open never moved, so the line
  reads as the posted age instead ("Posted 3 days ago").
  """
  def status_changed_label(post) do
    case post.status_changed_at do
      %DateTime{} = at -> "#{status_label(post.status)} #{time_ago(at)}"
      nil -> "Posted #{time_ago(post.created_at)}"
    end
  end

  @doc """
  Relative age in plain words ("2 days ago", "just now"). The only
  prior helper in the repo is BackupsComponent's private time_ago/2 —
  ops-terse units and a defp, not reachable here — so this owns the
  public-page wording. Clock skew (a future timestamp) reads as fresh.
  """
  def time_ago(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> ago(div(seconds, 60), "minute")
      seconds < 86_400 -> ago(div(seconds, 3_600), "hour")
      seconds < 604_800 -> ago(div(seconds, 86_400), "day")
      seconds < 2_629_800 -> ago(div(seconds, 604_800), "week")
      seconds < 31_557_600 -> ago(div(seconds, 2_629_800), "month")
      true -> ago(div(seconds, 31_557_600), "year")
    end
  end

  @doc "Counted noun phrase: count_label(3, :vote) reads as 3 votes."
  def count_label(count, unit), do: "#{count} #{unit}#{plural_suffix(count)}"

  @doc """
  The islands' vote count (ngettext so translations carry the plural):
  one copy here — the vote island's counter and the composer's
  Already-posted rows render the same shape.
  """
  def votes_label(count), do: ngettext("1 vote", "%{count} votes", count)

  @doc """
  The board's empty-state title. An empty BOARD and a FILTER that
  matched nothing are different sentences: "No posts yet." is only true
  of the unfiltered board (prod at launch), while a populated board with
  a zero-match filter must not claim there are no posts. The status
  filter names the status; anything riding a tag filter (tag only or
  combined) names the tag — the more specific chip.
  """
  def empty_title(nil, nil), do: gettext("No posts yet.")
  def empty_title(nil, _tag), do: gettext("No posts with this tag yet.")
  def empty_title(_status, nil), do: gettext("No posts with this status yet.")
  def empty_title(_status, _tag), do: gettext("No posts with this tag yet.")

  # Board URL for a view state; defaults collapse to the bare
  # /feedback so the canonical shape never accumulates query noise.
  # The keyword list rides into encode_query unconverted, so param
  # order is stable (first the sort, then the status, then the tag,
  # then the page).
  def board_href(sort, status, page, tag \\ nil) do
    candidates = [sort: sort, status: status && Atom.to_string(status), tag: tag, page: page]
    params = Enum.reject(candidates, &default_view?/1)

    if params == [] do
      "/feedback"
    else
      "/feedback?" <> URI.encode_query(params)
    end
  end

  defp default_view?({_key, nil}), do: true
  defp default_view?({_key, "top"}), do: true
  defp default_view?({_key, 1}), do: true
  defp default_view?(_kv), do: false

  defp ago(n, unit), do: "#{n} #{unit}#{plural_suffix(n)} ago"

  defp plural_suffix(1), do: ""
  defp plural_suffix(_n), do: "s"
end
