defmodule FluxValeWeb.OrganizationLive.Settings do
  @moduledoc """
  Org settings (#276): the tabbed shell with the General tab — display
  name and URL-slug rename, GitHub-parity. Slug-keyed mount like the
  catalog; unknown slugs (and policy denials) read as "not here" —
  never a bare 404.

  A slug change takes an explicit confirm step, and the step is bound to
  its proposal: `pending_slug` holds the slug the visible copy names, a
  confirm applies exactly that value, and any edit disarms — a rename
  can only land through a panel the user actually saw. Links to the old
  address stop working, the old slug is released to others, and no
  redirect is created; the copy says so before the rename applies.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Accounts.Organization
  alias FluxVale.Checks.ActorIsOrganizationOwner

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Organization.get_by_slug(slug, actor: user) do
      {:ok, org} ->
        # UX gate, not the authority: the update action's owner policy is
        # what actually forbids a non-owner save. This just spares a
        # member a form that could never go through.
        if ActorIsOrganizationOwner.owner?(user, org) do
          {:ok, assign(socket, org: org, form: build_form(org, user), pending_slug: nil)}
        else
          {:ok,
           socket
           |> put_flash(:error, "Only organization owners can access settings.")
           |> push_navigate(to: ~p"/")}
        end

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"organization" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    {:noreply, assign(socket, form: form, pending_slug: rearm(socket, form, params))}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    cond do
      # Invalid input never earns the confirm step — the field error
      # shows first (validate surfaces format errors eagerly).
      AshPhoenix.Form.errors(form) != [] ->
        {:noreply, assign(socket, form: form, pending_slug: nil)}

      # A slug change lands ONLY through the confirm step: every save
      # (re-)arms the panel for exactly the submitted slug.
      slug_changed?(socket.assigns.org, params) ->
        {:noreply, assign(socket, form: form, pending_slug: params["slug"])}

      true ->
        socket = assign(socket, :pending_slug, nil)
        apply_update(socket, form)
    end
  end

  # Guarded: only an armed panel can apply a rename, and it applies the
  # armed value — an unarmed click is a no-op (any edit disarms first,
  # see rearm/3), so a crafted event can never rename on its own.
  def handle_event("confirm-rename", _params, socket) do
    case socket.assigns.pending_slug do
      nil -> {:noreply, socket}
      _armed -> apply_update(socket, socket.assigns.form)
    end
  end

  def handle_event("cancel-rename", _params, socket) do
    {:noreply, assign(socket, :pending_slug, nil)}
  end

  defp apply_update(socket, form) do
    case AshPhoenix.Form.submit(form, params: form.params) do
      {:ok, org} ->
        socket = put_flash(socket, :info, "Organization updated.")

        if org.slug == socket.assigns.org.slug do
          # A name-only save stays put — the page already lives at this
          # address; header and form refresh in place.
          {:noreply,
           assign(socket,
             org: org,
             form: build_form(org, socket.assigns.current_user),
             pending_slug: nil
           )}
        else
          # The page now lives at the org's new slug.
          {:noreply, push_navigate(socket, to: ~p"/organizations/#{org.slug}/settings")}
        end

      {:error, form} ->
        # A stale view — the org renamed elsewhere since this page's
        # mount — must read as "reload", not as a validation problem.
        socket =
          if stale?(form) do
            put_flash(
              socket,
              :error,
              "This organization changed underneath you — reload to continue."
            )
          else
            put_flash(socket, :error, "Could not save — check the errors below.")
          end

        {:noreply, assign(socket, form: form, pending_slug: nil)}
    end
  end

  # The arm survives only while the field still holds exactly what was
  # armed and the input stays valid: an edit, a revert to the current
  # slug, or a format error disarms, and the next save re-arms. The
  # applied rename is therefore always a value the visible copy named.
  defp rearm(socket, form, params) do
    armed = socket.assigns.pending_slug

    cond do
      is_nil(armed) -> nil
      AshPhoenix.Form.errors(form) != [] -> nil
      params["slug"] != armed -> nil
      true -> armed
    end
  end

  # StaleRecord = another writer moved the row between this page's mount
  # and the submit (the update action filters on the loaded slug).
  defp stale?(form) do
    errors = form.source.source.errors
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp build_form(org, user) do
    org
    |> AshPhoenix.Form.for_update(:update, actor: user, as: "organization")
    |> to_form()
  end

  defp slug_changed?(org, params), do: params["slug"] != org.slug

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto max-w-3xl space-y-8">
        <div>
          <.button variant="ghost" size="sm" navigate={~p"/"} class="-ml-2 mb-4">
            &larr; Dashboard
          </.button>

          <div class="flex items-center gap-4">
            <div class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-primary-muted text-lg font-semibold text-primary">
              {String.first(@org.name)}
            </div>
            <div class="min-w-0">
              <h1
                class="truncate text-2xl font-semibold tracking-tight text-ink"
                data-testid="org-name"
              >
                {@org.name}
              </h1>
              <p class="text-sm text-ink-muted" data-testid="org-slug">{@org.slug}</p>
            </div>
          </div>
        </div>

        <.settings_tabs current="general" slug={@org.slug} />

        <.card id="org-general-card" class="space-y-4">
          <div>
            <h2 class="text-base font-medium text-ink">General</h2>
            <p class="mt-1 text-sm text-ink-muted">
              Your organization's display name and its address on FluxVale.
            </p>
          </div>

          <.form
            for={@form}
            id="org-general-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.input
              field={@form[:name]}
              label="Name"
              maxlength={100}
              required
              data-testid="org-name-input"
            />
            <.input
              field={@form[:slug]}
              label="Slug"
              maxlength={39}
              required
              data-testid="org-slug-input"
            />
            <p class="text-xs text-ink-subtle" data-testid="slug-preview">
              Your organization will live at
              <span class="font-mono text-ink-muted">/organizations/{@form[:slug].value}</span>
            </p>

            <.callout
              :if={@pending_slug}
              id="slug-confirm"
              tone="warning"
              title="Renaming changes this organization's address"
              data-testid="slug-confirm"
            >
              <p>
                Links to <span class="font-mono">/organizations/{@org.slug}</span> will stop
                working and <span class="font-mono">/organizations/{@pending_slug}</span> becomes
                the address. The old slug is released for anyone to claim, and no redirect is
                created.
              </p>
              <div class="flex gap-3 pt-1">
                <.button
                  type="button"
                  phx-click="confirm-rename"
                  size="sm"
                  data-testid="confirm-rename"
                >
                  Rename organization
                </.button>
                <.button
                  variant="ghost"
                  type="button"
                  phx-click="cancel-rename"
                  size="sm"
                  data-testid="cancel-rename"
                >
                  Cancel
                </.button>
              </div>
            </.callout>

            <div class="flex justify-end">
              <.button type="submit" data-testid="org-save">
                Save changes
              </.button>
            </div>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr(:current, :string, required: true)
  attr(:slug, :string, required: true)

  # One line per tab — the Members tab lands here with its ticket, the
  # Access tab with its lane. No dead tabs ship: the list carries only
  # what exists.
  defp settings_tabs(assigns) do
    tabs = [
      %{key: "general", label: "General", path: ~p"/organizations/#{assigns.slug}/settings"}
    ]

    assigns = assign(assigns, :tabs, tabs)

    ~H"""
    <nav
      class="flex gap-1 border-b border-line"
      aria-label="Organization settings"
      data-testid="org-settings-tabs"
    >
      <.link
        :for={tab <- @tabs}
        navigate={tab.path}
        aria-current={tab.key == @current && "page"}
        class={[
          "-mb-px rounded-t-lg border-b-2 px-3 py-2 text-sm font-medium transition-colors",
          tab.key == @current && "border-primary text-ink",
          tab.key != @current && "border-transparent text-ink-muted hover:text-ink"
        ]}
        data-testid={"org-settings-tab-#{tab.key}"}
      >
        {tab.label}
      </.link>
    </nav>
    """
  end
end
