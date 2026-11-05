defmodule FluxValeWeb.FeedbackLive.VoteIsland do
  @moduledoc """
  The post page's vote island (fluxvale/fluxvale#412, T5, ADR-0026 S4):
  the live count plus the cast/retract toggle, mounted on the SSR post
  page over `live_render` (the pricing-calculator precedent). The
  initial render is server-side, so the count stays crawlable.

  Three states, branched on the SHARED gate predicate
  (`ActorOwnsPaidOrg.board_write_allowed?/2` — never a forked notion):

  - anonymous: a sign-in CTA.
  - authed but the gate would refuse the selected org: the paying copy
    with a top-up link for that org.
  - eligible: the working toggle.

  The picker lists the actor's OWNED orgs only (the gate is ownership)
  and appears only when there are several; the default is the personal
  org (`FeedbackLive.OrgChoice`). The toggle names the selected org and
  reflects its voted state; switching orgs re-reads that org's state.
  Cast and retract call `FluxVale.Feedback.Vote` through the domain's
  code interface, so the actions' policies stay the gate: a tampered
  client can click anything, the write still refuses. Errors render
  inline, the count unchanged.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Checks.ActorOwnsPaidOrg
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Vote
  alias FluxValeWeb.FeedbackLive.OrgChoice
  alias FluxValeWeb.Locale
  alias FluxValeWeb.UserAuth

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # No live_session carries the locale hook for a controller-embedded
    # child (the pricing-calculator posture): mount re-resolves it.
    Gettext.put_locale(FluxValeWeb.Gettext, Locale.resolve(session))

    user = UserAuth.resolve_user(session)
    orgs = if user, do: OrgChoice.choices(user), else: []
    default = user && OrgChoice.default(user, orgs)
    post = post_by_slug(session["slug"])

    socket =
      socket
      |> assign(user: user, orgs: orgs, error: nil)
      |> assign(post: post, count: post && post.vote_count)
      |> select_org(default && default.id)

    {:ok, socket}
  end

  # An org pick re-derives the whole state for THAT org: the gate
  # answer, the voted row, and the count stay the post's.
  @impl Phoenix.LiveView
  def handle_event("pick-org", %{"org-id" => org_id}, socket) do
    org = Enum.find(socket.assigns.orgs, &(&1.id == org_id))

    case org do
      # The rendered chips cannot produce an unknown id; a crafted one
      # is silence.
      nil ->
        {:noreply, socket}

      org ->
        {:noreply, select_org(socket, org.id)}
    end
  end

  # The toggle: retract when the selected org has voted, cast when it
  # has not. The handler never pre-checks the gate beyond what the
  # render shows — the action's policy is the authority, so a tampered
  # client gains nothing. A post deleted between the SSR render and the
  # island's connect leaves the handlers silent (the UI is affordance
  # only: nothing to attach a vote to, nothing to crash on).
  @impl Phoenix.LiveView
  def handle_event("toggle", _params, %{assigns: %{post: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("toggle", _params, %{assigns: %{user: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("toggle", _params, socket) do
    outcome = toggle_vote(socket.assigns)

    case outcome do
      :retracted ->
        {:noreply,
         socket
         |> assign(voted: nil, error: nil)
         |> assign(count: vote_count(socket.assigns.post))}

      {:cast, vote} ->
        {:noreply,
         socket
         |> assign(voted: vote, error: nil)
         |> assign(count: vote_count(socket.assigns.post))}

      # The race arms (the org lost its paid arm mid-session, another
      # tab already cast): inline copy, state and count unchanged.
      {:error, _refused} ->
        {:noreply, assign(socket, error: gettext("Your vote didn't go through. Try again."))}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, selected_org: selected_org(assigns))

    ~H"""
    <div
      :if={@post}
      id="vote-island"
      data-testid="vote-island"
      class="flex flex-wrap items-center justify-between gap-3 rounded-panel border border-line bg-panel px-4 py-3"
    >
      <span class="flex items-center gap-1.5 text-sm font-medium text-ink" data-testid="vote-count">
        <.icon name="hero-hand-thumb-up" class="size-4 text-ink-muted" />
        {votes_label(@count)}
      </span>

      <span :if={@gate == :anonymous}>
        <.link
          href={~p"/sign-in"}
          data-testid="vote-sign-in"
          class="text-sm font-medium text-link hover:underline"
        >
          {gettext("Sign in to vote")}
        </.link>
      </span>

      <span :if={@gate == :allowed}>
        <button
          type="button"
          id="vote-toggle"
          data-testid="vote-toggle"
          phx-click="toggle"
          aria-pressed={to_string(not is_nil(@voted))}
          aria-label={if(is_nil(@voted), do: gettext("Cast vote"), else: gettext("Retract vote"))}
          phx-disable-with={gettext("Saving…")}
          class={[
            "rounded-control border px-3 py-1.5 text-sm font-medium shadow-sm transition-colors duration-(--motion-fast) outline-offset-2 outline-focus focus-visible:outline-2",
            if(is_nil(@voted),
              do: "border-line-primary bg-primary text-on-primary hover:bg-primary-hover",
              else: "border-primary/40 bg-primary-muted text-link hover:border-primary"
            )
          ]}
        >
          {toggle_label(is_nil(@voted), @selected_org.name)}
        </button>
      </span>

      <%!-- The picker rides the actor's owned orgs, whatever the
      selected org's gate state: a multi-org owner with an unpaid
      personal org must be able to switch to their paid team one. Chips
      only when the actor owns several, default first (personal). --%>
      <div
        :if={@gate != :anonymous and length(@orgs) > 1}
        id="vote-org-picker"
        role="group"
        aria-label={gettext("Vote as")}
        class="flex w-full flex-wrap items-center gap-2"
      >
        <button
          :for={org <- @orgs}
          type="button"
          id={"vote-org-#{org.slug}"}
          phx-click="pick-org"
          phx-value-org-id={org.id}
          aria-pressed={to_string(org.id == @selected_org_id)}
          class={[
            "rounded-full border px-3 py-1 text-xs font-medium transition-colors duration-(--motion-fast)",
            if(org.id == @selected_org_id,
              do: "border-primary/25 bg-primary-muted text-link",
              else: "border-line bg-panel text-ink-muted hover:text-ink"
            )
          ]}
        >
          {org.name}
        </button>
      </div>

      <p :if={@gate == :refused} data-testid="vote-gate-copy" class="w-full text-sm text-ink-muted">
        {gettext("Voting needs a paid org.")}
        <.link
          href={OrgChoice.topup_path(@selected_org)}
          data-testid="vote-topup"
          class="font-medium text-link hover:underline"
        >
          {topup_label(@selected_org)}
        </.link>
      </p>

      <p
        :if={@error}
        id="vote-error"
        data-testid="vote-error"
        class="w-full text-sm text-danger"
        role="alert"
      >
        {@error}
      </p>
    </div>
    """
  end

  # --- State derivation -------------------------------------------------------

  # One selector for mount and org picks, so every derived assign moves
  # together and no render can disagree with the selection. A missing
  # post (deleted between the page load and the island's connect) never
  # renders, so the gate label here is dead weight — it just keeps the
  # assigns total. A nil org fails closed at the shared predicate.
  defp select_org(%{assigns: %{post: nil}} = socket, _org_id) do
    assign(socket, selected_org_id: nil, gate: :refused, voted: nil)
  end

  defp select_org(socket, org_id) do
    gate =
      cond do
        is_nil(socket.assigns.user) -> :anonymous
        gate_allows?(socket.assigns.user, org_id) -> :allowed
        true -> :refused
      end

    voted =
      if gate == :allowed do
        find_vote(socket.assigns.post.id, org_id)
      else
        nil
      end

    assign(socket, selected_org_id: org_id, gate: gate, voted: voted)
  end

  # The shared predicate — the same answer the actions' policies give;
  # a nil org fails closed inside it.
  defp gate_allows?(user, org_id),
    do: ActorOwnsPaidOrg.board_write_allowed?(user, org_id)

  defp selected_org(assigns) do
    Enum.find(assigns.orgs, &(&1.id == assigns.selected_org_id))
  end

  # --- Writes -------------------------------------------------------------------

  defp toggle_vote(assigns) do
    if assigns.voted do
      case Vote.retract(assigns.voted, actor: assigns.user) do
        :ok -> :retracted
        {:error, _refused} -> {:error, :retract}
      end
    else
      case Vote.cast(%{post_id: assigns.post.id, organization_id: assigns.selected_org_id},
             actor: assigns.user
           ) do
        {:ok, vote} -> {:cast, vote}
        {:error, _refused} -> {:error, :cast}
      end
    end
  end

  # --- Reads ----------------------------------------------------------------------

  defp post_by_slug(slug) when is_binary(slug) do
    result =
      Post
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(slug == ^slug)
      |> Ash.read_one(actor: nil)

    case result do
      {:ok, %Post{} = post} -> post
      _missing -> nil
    end
  end

  # The page's island mounts after a post was deleted mid-session; a
  # keyless session is a programming error, and the island degrading to
  # nothing beats a mount crash if the caller contract ever drifts.
  # coveralls-ignore-next-line
  defp post_by_slug(_missing), do: nil

  defp find_vote(post_id, org_id) do
    Vote
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(post_id == ^post_id and organization_id == ^org_id)
    |> Ash.read_one!(actor: nil)
  end

  defp vote_count(post), do: Ash.get!(Post, post.id, actor: nil).vote_count

  # --- Copy -----------------------------------------------------------------------

  defp votes_label(count), do: FluxValeWeb.FeedbackHTML.votes_label(count)

  defp toggle_label(true, org), do: gettext("Vote as %{org}", org: org)
  defp toggle_label(false, org), do: gettext("Voted as %{org}", org: org)

  # The org-less shape never reaches the render (a sign-in without an
  # owned org fails the auth chain); the generic label keeps the copy
  # total if that ever drifts. The pure arm is covered directly in
  # OrgChoiceTest.
  # coveralls-ignore-next-line
  defp topup_label(nil), do: gettext("Top up to vote")

  defp topup_label(org), do: gettext("Top up %{org} to vote", org: org.name)
end
