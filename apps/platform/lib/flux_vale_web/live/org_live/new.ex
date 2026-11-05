defmodule FluxValeWeb.OrganizationLive.New do
  @moduledoc """
  The org creation page (#408): the switcher footer entry's target — the
  owner's original ask. Name + address slug, submitted straight onto the
  `:create_with_owner` action through an AshPhoenix.Form (ADR-0002
  forms-straight-onto-resources); `Accounts.create_organization/2` is the
  same seam. Success redirects flash-free to the new org's home — its
  empty state already says "Deploy this organization's first app from the
  catalog."

  The slug suggestion is a HINT derived from the name on validate (plain
  Elixir in this LiveView, never a JS fork of the slug regex): the
  server's validations stay the authority, the hint can still collide or
  hit a reserved word, and the user can edit the slug freely. The cap
  refusal (an actor at the ten-org cap) is not a field problem — it
  surfaces as a friendly flash instead.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorBelowOrgCreateCap

  # The actor path's slug cap (create_with_owner's string_length) — the
  # hint truncates to it so the suggestion never sets the user up for a
  # cap error. Mirrors the settings page's maxlength.
  @slug_cap 39

  # The mount-time gate IS the live_session: :authenticated's on_mount
  # chain (UserAuth.ensure_authenticated) redirects anonymous traffic to
  # /sign-in before this mount runs — no extra guard here.
  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(form: build_form(socket.assigns.current_user))
      |> assign(slug_source: :name)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"organization" => params}, socket) do
    {params, source} = reconcile_slug(params, socket.assigns)
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    {:noreply, assign(socket, form: form, slug_source: source)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"organization" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    case AshPhoenix.Form.submit(form, params: form.params) do
      {:ok, org} ->
        # Flash-free: nothing failed, and the org home's empty state is
        # the welcome.
        {:noreply, push_navigate(socket, to: ~p"/organizations/#{org.slug}")}

      {:error, form} ->
        if field_free?(form) and cap_refused?(socket.assigns.current_user) do
          # The cap refusal rides no field (Forbidden.Policy implements
          # no AshPhoenix.FormData.Error), so field-scoped errors take
          # precedence — the flash must not misdiagnose an at-cap
          # user's bad-format submit. Classification re-runs the cap
          # count the refusing policy just used (ActorBelowOrgCreateCap.
          # below_cap?/1). A membership removed in that re-run gap
          # reclassifies the refusal as silent — cosmetic only; the
          # gate is and stays the policy's.
          #
          # Copy ties to ActorBelowOrgCreateCap's @org_create_cap — the
          # NewTest flash assertion catches drift between the two.
          {:noreply,
           socket
           |> put_flash(
             :error,
             "You already own 10 organizations. That is the limit for now."
           )
           |> assign(:form, form)}
        else
          # Field problems stay field-scoped under the inputs.
          {:noreply, assign(socket, :form, form)}
        end
    end
  end

  # AshPhoenix.Form.errors/1 is the field-error surface; a cap refusal
  # never lands there (probed: [] on an over-cap submit).
  defp field_free?(form), do: AshPhoenix.Form.errors(form) == []

  defp cap_refused?(user) do
    not ActorBelowOrgCreateCap.below_cap?(user)
  end

  # The hint follows the name only while the slug field itself has not
  # been typed into (the :name source). An incoming slug that differs
  # from the rendered one is the user's edit — the field stops following
  # the name from then on.
  defp reconcile_slug(params, assigns) do
    rendered = assigns.form[:slug].value || ""
    incoming = Map.get(params, "slug", "")

    if assigns.slug_source == :user or incoming != rendered do
      {params, :user}
    else
      {Map.put(params, "slug", slug_suggestion(params["name"])), :name}
    end
  end

  # The slug rules as a derivation: lowercase, runs of anything else
  # become one hyphen, hyphens trimmed off the ends, then the cap. An
  # all-invalid name derives "" — the empty field, not an error (the
  # server's validations are the authority).
  defp slug_suggestion(name) when name in [nil, ""], do: ""

  defp slug_suggestion(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")

    slug
    |> String.trim("-")
    |> String.slice(0, @slug_cap)
    |> String.trim_trailing("-")
  end

  defp build_form(user) do
    Organization
    |> AshPhoenix.Form.for_create(:create_with_owner,
      actor: user,
      as: "organization",
      # The cap refusal is an expected path here, and it is the ONE
      # error this form can produce that no field can carry
      # (Forbidden.Policy implements no FormData.Error) — the default
      # warn-on-unhandled would log ops-visible warning noise + policy
      # breadcrumbs on every refusal, reading like a production bug.
      # Field errors implement the protocol and are unaffected.
      warn_on_unhandled_errors?: false
    )
    |> to_form()
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      actor_orgs={@actor_orgs}
      personal_org_id={@personal_org_id}
      username={@username}
      nav_section={@nav_section}
      bare
    >
      <%!-- App-wide grammar page (S10): `bare` main + .appgram — the
      page owns ALL of main's rhythm. The small page: the band names the
      act (no org band — there is no org yet), the one card carries the
      form. --%>
      <div class="appgram contents">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <.link
                navigate={~p"/"}
                data-testid="org-new-back"
                class="inline-flex items-center gap-1.5 text-sm text-ink-muted transition-colors hover:text-ink"
              >
                <span aria-hidden="true">&larr;</span> Dashboard
              </.link>
              <div class="mt-3 min-w-0">
                <p class="eyebrow">Organizations</p>
                <h1 class="page-title mt-1.5" data-testid="org-new-title">
                  Create an Organization
                </h1>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise max-w-2xl space-y-4">
            <.form
              for={@form}
              id="org-new-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <.card id="org-new-card" class="space-y-4">
                <div>
                  <h2 class="text-base font-medium text-ink">New organization</h2>
                  <p class="mt-1 text-sm text-ink-muted">
                    A team space for apps and instances, separate from your personal account.
                  </p>
                </div>

                <.input
                  field={@form[:name]}
                  label="Organization name"
                  maxlength={100}
                  required
                  data-testid="org-new-name-input"
                />
                <.input
                  field={@form[:slug]}
                  label="Slug"
                  maxlength={39}
                  required
                  data-testid="org-new-slug-input"
                />
                <p class="text-xs text-ink-subtle" data-testid="slug-preview">
                  Your organization will live at
                  <span class="font-mono text-ink-muted">/organizations/{@form[:slug].value}</span>
                </p>

                <div class="flex justify-end">
                  <.button type="submit" data-testid="org-new-save">
                    Create organization
                  </.button>
                </div>
              </.card>
            </.form>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
