defmodule FluxValeWeb.FeedbackLive.Composer do
  @moduledoc """
  The feedback composer (fluxvale/fluxvale#412, T5, ADR-0026 S4): the
  full-page LiveView at /feedback/new — a fixed route under /feedback,
  so the router declares it BEFORE :show's /feedback/:slug (the
  /blog/feed lesson; the "new" slug reservation in DeriveSlug covers the
  URL either way).

  Title, description, and the org picker (the vote island's shared
  `FeedbackLive.OrgChoice` state) — no tag picker in this slice. While
  the title types, a debounced search runs the domain's
  `similar_posts/1` and renders the "Already posted?" nudge, so dupes
  fold into their originals instead of splitting votes.

  The same three states as the vote island, branched on the SHARED gate
  predicate (`ActorOwnsPaidOrg.board_write_allowed?/2`): anonymous sees
  a sign-in CTA, authed-but-ineligible sees honest gate copy with a
  top-up link, eligible actors get the working form. The UI is
  affordance only — the create's policy is the gate — so a tampered
  client's submit is refused inline, never silently honored.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Checks.ActorOwnsPaidOrg
  alias FluxVale.Feedback
  alias FluxVale.Feedback.Post
  alias FluxValeWeb.FeedbackLive.OrgChoice
  alias FluxValeWeb.UserAuth

  # The title search's keystroke rate limiter (the input's phx-debounce).
  @debounce_ms 300

  on_mount({FluxValeWeb.Locale, :set_locale})

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    user = UserAuth.resolve_user(session)
    orgs = if user, do: OrgChoice.choices(user), else: []
    default = user && OrgChoice.default(user, orgs)

    socket =
      assign(socket,
        user: user,
        orgs: orgs,
        selected_org_id: default && default.id,
        gate: gate(user, default && default.id),
        suggestions: [],
        searched_title: nil,
        error: nil,
        form: form_for(user),
        debounce_ms: @debounce_ms,
        page_title: gettext("Post a request - FluxVale")
      )

    {:ok, socket}
  end

  # The title drives the similar-posts nudge: a debounced input fires
  # validate, and an unchanged title skips the search (the description's
  # keystrokes reuse the last result). The wire nests under the form's
  # `as`; AshPhoenix takes the inner params (the deploy stepper's
  # posture). A crafted non-binary title sanitizes to an empty string
  # for the form (a map has no HTML render) while the raw value rides
  # to the search, which answers silence.
  @impl Phoenix.LiveView
  def handle_event("validate", %{"post" => params}, socket) do
    merged = Map.merge(socket.assigns.form.params, params)
    title = merged["title"]

    form_params =
      if is_binary(title) do
        merged
      else
        Map.put(merged, "title", "")
      end

    form = AshPhoenix.Form.validate(socket.assigns.form, form_params)

    socket =
      if title == socket.assigns.searched_title do
        assign(socket, form: form)
      else
        socket
        |> assign(form: form, suggestions: Feedback.similar_posts(title))
        |> assign(searched_title: title)
      end

    {:noreply, socket}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("pick-org", %{"org-id" => org_id}, socket) do
    case Enum.find(socket.assigns.orgs, &(&1.id == org_id)) do
      # The rendered chips cannot produce an unknown id; a crafted one
      # is silence.
      nil ->
        {:noreply, socket}

      org ->
        {:noreply,
         socket
         |> assign(selected_org_id: org.id)
         |> assign(gate: gate(socket.assigns.user, org.id))}
    end
  end

  # The submit never pre-checks the gate beyond what the render shows —
  # the create's policy is the authority, so a tampered client gains
  # nothing (the refusal renders inline).
  @impl Phoenix.LiveView
  def handle_event("create", _params, %{assigns: %{user: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("create", %{"post" => params}, socket) do
    # Invalid input never earns the write — the field errors show first
    # (the settings posture). The wire nests under the form's `as`;
    # AshPhoenix takes the inner params.
    form_params =
      socket.assigns.form.params
      |> Map.merge(params)
      |> Map.put("organization_id", socket.assigns.selected_org_id)

    form = AshPhoenix.Form.validate(socket.assigns.form, form_params)

    if AshPhoenix.Form.errors(form) != [] do
      {:noreply, assign(socket, form: form)}
    else
      # The org the write NAMES is the picker's selection, server-side
      # — never a field the client could carry in.
      case AshPhoenix.Form.submit(socket.assigns.form, params: form_params) do
        {:ok, post} ->
          # The landing is the SSR post page (a controller render, not
          # a live route) — a plain redirect, flash riding the session.
          {:noreply,
           socket
           |> put_flash(:info, gettext("Request posted."))
           |> redirect(to: ~p"/feedback/#{post.slug}")}

        # Past validation, the only refusal the create can answer is the
        # paying gate's — and the form cannot carry policy errors (no
        # FormData impl), so the copy renders inline (the affordance
        # said so; the policy confirms). The "Unhandled error in form
        # submission" log line AshPhoenix emits for exactly this shape
        # is deliberate noise: the refusal is handled, one layer up.
        {:error, _form} ->
          {:noreply, assign(socket, error: gettext("Posting needs a paid org."))}
      end
    end
  end

  def handle_event("create", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, selected_org: selected_org(assigns))

    ~H"""
    <Layouts.public flash={@flash} current_user={@user}>
      <article class="mx-auto w-full max-w-2xl">
        <.button variant="ghost" size="sm" navigate={~p"/feedback"} class="-ml-2 mb-4">
          &larr; Feedback
        </.button>

        <.header>
          {gettext("Post a request")}
          <:subtitle>
            {gettext("Tell us what to build next. Every post is public and tracked by the team.")}
          </:subtitle>
        </.header>

        <div :if={is_nil(@user)} class="mt-6 rounded-panel border border-line bg-panel px-4 py-6">
          <p class="text-sm text-ink-muted">
            {gettext("Sign in to post a request.")}
            <.link
              href={~p"/sign-in"}
              data-testid="composer-sign-in"
              class="font-medium text-link hover:underline"
            >
              {gettext("Sign in")}
            </.link>
          </p>
        </div>

        <div :if={@form} class="mt-6">
          <.form
            for={@form}
            id="composer-form"
            phx-change="validate"
            phx-submit="create"
            class="space-y-5"
          >
            <.input
              field={@form[:title]}
              type="text"
              label={gettext("Title")}
              placeholder={gettext("Short and specific wins the most votes.")}
              maxlength={140}
              phx-debounce={@debounce_ms}
              data-testid="composer-title"
            />
            <.input
              field={@form[:description]}
              type="textarea"
              label={gettext("Description")}
              placeholder={gettext("What should happen, and why it matters.")}
              rows={6}
              maxlength={5000}
              data-testid="composer-description"
            />

            <div>
              <p id="composer-org-label" class="mb-2 text-sm font-medium text-ink">
                {gettext("Post as")}
              </p>
              <div
                id="composer-org-picker"
                data-testid="composer-org-picker"
                role="group"
                aria-labelledby="composer-org-label"
                class="flex flex-wrap items-center gap-2"
              >
                <button
                  :for={org <- @orgs}
                  type="button"
                  id={"composer-org-#{org.slug}"}
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
            </div>

            <div
              :if={@gate == :refused}
              data-testid="composer-gate-copy"
              class="text-sm text-ink-muted"
            >
              <p>
                {gettext("Posting needs a paid org.")}
                <.link
                  href={OrgChoice.topup_path(@selected_org)}
                  data-testid="composer-topup"
                  class="font-medium text-link hover:underline"
                >
                  {topup_label(@selected_org)}
                </.link>
              </p>
            </div>

            <.button
              :if={@gate == :allowed}
              type="submit"
              data-testid="composer-submit"
              phx-disable-with={gettext("Posting…")}
            >
              {gettext("Post request")}
            </.button>
          </.form>

          <p
            :if={@error}
            id="composer-error"
            data-testid="composer-error"
            class="mt-3 text-sm text-danger"
            role="alert"
          >
            {@error}
          </p>
        </div>

        <%!-- The dupe nudge: the top matches for the title so far,
        ranked by shared tokens then votes (SimilarPosts' contract). --%>
        <div
          :if={@suggestions != []}
          id="similar-posts"
          data-testid="similar-posts"
          class="mt-8 rounded-panel border border-line-warning bg-warning-muted px-4 py-4"
        >
          <p class="text-sm font-medium text-ink">{gettext("Already posted?")}</p>
          <ul class="mt-2 space-y-2">
            <li :for={post <- @suggestions} data-testid={"similar-post-#{post.slug}"}>
              <.link
                href={~p"/feedback/#{post.slug}"}
                class="text-sm font-medium text-link hover:underline"
              >
                {post.title}
              </.link>
              <span class="ml-2 text-xs text-ink-muted">{votes_label(post.vote_count)}</span>
            </li>
          </ul>
        </div>
      </article>
    </Layouts.public>
    """
  end

  # --- State derivation -------------------------------------------------------

  # Anonymous wins the label war: a visitor with no org at all sees the
  # sign-in CTA, not paying copy.
  defp gate(nil, _org_id), do: :anonymous

  # The org-less shape never reaches the composer (a sign-in without an
  # owned org fails the auth chain); the :refused label keeps mount
  # total if that ever drifts.
  # coveralls-ignore-next-line
  defp gate(_user, nil), do: :refused

  # The shared predicate — the same answer the create's policy gives.
  defp gate(user, org_id) do
    if ActorOwnsPaidOrg.board_write_allowed?(user, org_id) do
      :allowed
    else
      :refused
    end
  end

  defp form_for(nil), do: nil

  defp form_for(user) do
    Post
    |> AshPhoenix.Form.for_create(:create, actor: user, as: "post")
    |> to_form()
  end

  defp selected_org(assigns) do
    Enum.find(assigns.orgs, &(&1.id == assigns.selected_org_id))
  end

  # --- Copy ---------------------------------------------------------------------

  # The org-less shape never reaches the render (a sign-in without an
  # owned org fails the auth chain); the generic label keeps the copy
  # total if that ever drifts. The pure arm is covered directly in
  # OrgChoiceTest.
  # coveralls-ignore-next-line
  defp topup_label(nil), do: gettext("Top up to post")

  defp topup_label(org), do: gettext("Top up %{org} to post", org: org.name)

  defp votes_label(count), do: FluxValeWeb.FeedbackHTML.votes_label(count)
end
