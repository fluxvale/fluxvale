defmodule FluxValeWeb.OrganizationLive.New do
  @moduledoc """
  The org creation page (#408): the switcher footer entry's target. One
  input, the name. The address derives from it on every validate — plain
  Elixir here, never a JS fork of the slug regex — and reads back live in
  the preview line; there is no manual slug field in v1. Submit sends
  name plus the derived slug straight onto the `:create_with_owner`
  action through an AshPhoenix.Form (ADR-0002
  forms-straight-onto-resources); `Accounts.create_organization/2` is
  the same seam. Success redirects flash-free to the new org's home —
  its empty state is the welcome, and carries the next step (invite
  people).

  The derivation is the only writer of the slug on this page. A derived
  address that fails a slug rule — taken, reserved, or any other —
  cannot be fixed by editing a slug input (there is none), so the failed
  submit says so in one plain line under the preview: adjust the name.
  An empty derivation (no name yet) is the preview's empty state
  instead. The cap refusal (an actor at the ten-org cap) is not a name
  problem at all — it surfaces as a friendly flash instead.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorBelowOrgCreateCap

  # The actor path's slug cap (create_with_owner's string_length) — the
  # derivation truncates to it so a derived address never sets the user
  # up for a cap error. Mirrors the settings page's maxlength.
  @slug_cap 39

  # The mount-time gate IS the live_session: :authenticated's on_mount
  # chain (UserAuth.ensure_authenticated) redirects anonymous traffic to
  # /sign-in before this mount runs — no extra guard here.
  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(form: build_form(socket.assigns.current_user))
      |> assign(address_refused?: false)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"organization" => params}, socket) do
    params = Map.put(params, "slug", slug_suggestion(params["name"]))
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    # A fresh input invalidates the refusal line: it described the
    # previous derivation, and this validate derived a new one.
    {:noreply, assign(socket, form: form, address_refused?: false)}
  end

  @impl Phoenix.LiveView
  def handle_event("save", %{"organization" => params}, socket) do
    params = Map.put(params, "slug", slug_suggestion(params["name"]))
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    case AshPhoenix.Form.submit(form, params: form.params) do
      {:ok, org} ->
        # Flash-free: nothing failed, and the org home's empty state is
        # the welcome.
        {:noreply, push_navigate(socket, to: ~p"/organizations/#{org.slug}")}

      {:error, form} ->
        socket =
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
            put_flash(
              socket,
              :error,
              "You already own 10 organizations. That is the limit for now."
            )
          else
            # The name's own problems render field-scoped; a refused
            # address renders as the one plain line under the preview.
            assign(socket, address_refused?: address_refused?(form, params["slug"]))
          end

        {:noreply, assign(socket, :form, form)}
    end
  end

  # AshPhoenix.Form.errors/1 is the field-error surface; a cap refusal
  # never lands there (probed: [] on an over-cap submit).
  defp field_free?(form), do: AshPhoenix.Form.errors(form) == []

  defp cap_refused?(user) do
    not ActorBelowOrgCreateCap.below_cap?(user)
  end

  # The one refusal line: the derived address failed a slug rule. An
  # empty derivation is NOT a refused address — it is the preview's
  # empty state (an address "taken" claim would be false there); the
  # name's own required error speaks for it.
  defp address_refused?(form, derived) do
    derived != "" and slug_errored?(form)
  end

  defp slug_errored?(form) do
    form
    |> AshPhoenix.Form.errors()
    |> Keyword.has_key?(:slug)
  end

  # The slug rules as a derivation: lowercase, runs of anything else
  # become one hyphen, hyphens trimmed off the ends, then the cap. An
  # all-invalid name derives "" — the preview's empty state, not an
  # error (the server's validations are the authority). The catch-all
  # keeps a crafted non-binary name (Plug parses form arrays as lists)
  # from crashing the socket — it derives "" and the name's own cast
  # error renders field-scoped.
  defp slug_suggestion(name) when name in [nil, ""], do: ""

  defp slug_suggestion(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")

    slug
    |> String.trim("-")
    |> String.slice(0, @slug_cap)
    |> String.trim_trailing("-")
  end

  defp slug_suggestion(_other), do: ""

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
                    A space for apps and instances, separate from your personal account.
                  </p>
                </div>

                <.input
                  field={@form[:name]}
                  label="Organization name"
                  maxlength={100}
                  required
                  data-testid="org-new-name-input"
                />

                <%!-- The derived address, visible before submitting. A
                plain element (not an input): the client never restores
                its value over the server's patch, so the live
                derivation cannot be clobbered. --%>
                <p class="text-xs text-ink-subtle" data-testid="slug-preview">
                  <%= if @form[:slug].value in [nil, ""] do %>
                    Add a name to see its address.
                  <% else %>
                    Your organization will live at
                    <span class="font-mono text-ink-muted">/organizations/{@form[:slug].value}</span>
                  <% end %>
                </p>

                <p :if={@address_refused?} class="text-xs text-ink" data-testid="address-refused">
                  That address won't work. Try a different name.
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
