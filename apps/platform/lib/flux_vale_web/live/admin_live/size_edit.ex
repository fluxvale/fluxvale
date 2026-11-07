defmodule FluxValeWeb.AdminLive.SizeEdit do
  @moduledoc """
  The admin size edit form (#501): the surgery surface over `Size`'s
  own `:update` action.

  Two panels, one action, the freeze made visible: prices (cents) are
  freely editable — prices-as-data is the whole point — while the
  allocation panels' controls lock when versions point at the size,
  with copy naming the count and the sanctioned path (re-point or
  retire first, then move the size). The lock is the UI explaining the
  resource's `ValidateAllocationFrozen`, never a bypass: the
  action-level validation stays the enforcement, and an unlocked size's
  form says its allocation will freeze once versions point here.

  Every write runs through the action with the platform-admin actor and
  `authorize?: true` — the domain policies decide, never the UI.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Pricing.Size
  alias FluxValeWeb.UserAuth

  require Ash.Query

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, session, socket) do
    admin = UserAuth.resolve_user(session)

    case Ash.get(Size, id, actor: admin, authorize?: true) do
      {:ok, size} ->
        referenced_count = referenced_versions_count(size.id, admin)

        {:ok,
         assign(socket,
           current_user: admin,
           actor_orgs: [],
           personal_org_id: nil,
           username: admin && admin.username,
           nav_section: nil,
           size: size,
           referenced_count: referenced_count,
           price_form: build_form(size, admin),
           allocation_form: build_form(size, admin)
         )}

      {:error, _not_found_or_denied} ->
        # Unknown id and policy denial read the same: this size is not
        # editable from here (the org-settings posture).
        {:ok,
         socket
         |> put_flash(:error, gettext("That size is not editable here."))
         |> push_navigate(to: ~p"/admin/catalog/sizes")}
    end
  end

  # The pre-write probe behind the lock: how many versions point at
  # this size. Display-only — the action re-checks on every save.
  defp referenced_versions_count(size_id, admin) do
    AppVersion
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(recommended_size_id == ^size_id)
    |> Ash.count!(actor: admin)
  end

  defp build_form(size, admin) do
    size
    |> AshPhoenix.Form.for_update(:update, as: "size", actor: admin, authorize?: true)
    |> to_form()
  end

  # cpu_cores is a Decimal on the record and a string in the params;
  # the input needs text (Decimal has no HTML-safe encoding).
  defp alloc_cpu_value(assigns) do
    case assigns.allocation_form.params["cpu_cores"] do
      nil -> Decimal.to_string(assigns.size.cpu_cores)
      value -> value
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate-price", %{"size" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.price_form, params)

    {:noreply, assign(socket, price_form: form)}
  end

  def handle_event("save-price", %{"size" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.price_form, params)

    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, size} ->
        admin = socket.assigns.current_user

        {:noreply,
         socket
         |> put_flash(:info, gettext("Prices saved."))
         |> assign(
           size: size,
           price_form: build_form(size, admin),
           allocation_form: build_form(size, admin)
         )}

      {:error, error_form} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save the prices. Check the errors below."))
         |> assign(price_form: to_form(error_form))}
    end
  end

  def handle_event("validate-allocation", %{"size" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.allocation_form, params)

    {:noreply, assign(socket, allocation_form: form)}
  end

  def handle_event("save-allocation", %{"size" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.allocation_form, params)

    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, size} ->
        # Re-probe on success so the lock copy can never go stale.
        admin = socket.assigns.current_user
        referenced_count = referenced_versions_count(size.id, admin)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Allocation saved."))
         |> assign(
           size: size,
           referenced_count: referenced_count,
           price_form: build_form(size, admin),
           allocation_form: build_form(size, admin)
         )}

      {:error, error_form} ->
        # The action-level freeze speaking (a crafted or raced write):
        # the honest error renders on the allocation fields.
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save the allocation. Check the errors below."))
         |> assign(allocation_form: to_form(error_form))}
    end
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
      <div class="appgram contents" data-testid="admin-size-edit">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">
                {gettext("Edit size")}
                <span class="ml-2 font-mono text-2xl text-ink-muted">{@size.slug}</span>
              </h1>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/catalog/sizes"}
                  data-testid="admin-sizes-back-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to the size ladder")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise grid gap-6 lg:grid-cols-2">
            <%!-- Prices: business data, freely editable — the admin path
            this resource exists for. --%>
            <.card class="space-y-4" data-testid="admin-size-prices">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("Prices")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext("Prices are business data. Edit them freely.")}
                </p>
              </div>

              <.form
                for={@price_form}
                id="size-price-form"
                phx-change="validate-price"
                phx-submit="save-price"
                class="space-y-4"
              >
                <.input
                  field={@price_form[:monthly_cents]}
                  type="number"
                  min="0"
                  label={gettext("Monthly rate (US cents)")}
                  data-testid="admin-size-price-monthly"
                />
                <.input
                  field={@price_form[:stopped_monthly_cents]}
                  type="number"
                  min="0"
                  label={gettext("Stopped rate (US cents)")}
                  data-testid="admin-size-price-stopped"
                />
                <.button type="submit" data-testid="admin-size-price-save">
                  {gettext("Save prices")}
                </.button>
              </.form>
            </.card>

            <%!-- Allocation: the freeze as UI. Locked sizes render
            disabled controls and no submit at all, with the count and
            the path named; free sizes render a live form and the
            warning that the freeze is one pointing-version away. --%>
            <.card class="space-y-4" data-testid="admin-size-allocation">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("Allocation")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext("The envelope a version's blueprint must match.")}
                </p>
              </div>

              <.callout
                :if={@referenced_count > 0}
                tone="warning"
                title={
                  ngettext(
                    "1 version points at this size",
                    "%{count} versions point at this size",
                    @referenced_count
                  )
                }
                data-testid="admin-size-freeze-lock"
              >
                <p>
                  {gettext(
                    "Its blueprint defaults must keep matching this envelope. Re-point those versions to another size, or retire them. Then this allocation can move."
                  )}
                </p>
              </.callout>

              <.callout
                :if={@referenced_count == 0}
                tone="info"
                title={gettext("No versions point at this size")}
                data-testid="admin-size-freeze-open"
              >
                <p>
                  {gettext("The allocation is editable now. It freezes once a version points here.")}
                </p>
              </.callout>

              <.form
                :if={@referenced_count == 0}
                for={@allocation_form}
                id="size-allocation-form"
                phx-change="validate-allocation"
                phx-submit="save-allocation"
                class="space-y-4"
              >
                <.input
                  field={@allocation_form[:cpu_cores]}
                  value={alloc_cpu_value(assigns)}
                  label={gettext("CPU cores")}
                  data-testid="admin-size-alloc-cpu"
                />
                <.input
                  field={@allocation_form[:memory_mb]}
                  type="number"
                  min="1"
                  label={gettext("Memory (MB)")}
                  data-testid="admin-size-alloc-memory"
                />
                <.input
                  field={@allocation_form[:storage_gb]}
                  type="number"
                  min="0"
                  label={gettext("Storage (GB)")}
                  data-testid="admin-size-alloc-storage"
                />
                <.button type="submit" data-testid="admin-size-alloc-save">
                  {gettext("Save allocation")}
                </.button>
              </.form>

              <div :if={@referenced_count > 0} class="space-y-4 opacity-60">
                <.input
                  field={@allocation_form[:cpu_cores]}
                  value={alloc_cpu_value(assigns)}
                  label={gettext("CPU cores")}
                  disabled
                  data-testid="admin-size-alloc-cpu"
                />
                <.input
                  field={@allocation_form[:memory_mb]}
                  type="number"
                  min="1"
                  label={gettext("Memory (MB)")}
                  disabled
                  data-testid="admin-size-alloc-memory"
                />
                <.input
                  field={@allocation_form[:storage_gb]}
                  type="number"
                  min="0"
                  label={gettext("Storage (GB)")}
                  disabled
                  data-testid="admin-size-alloc-storage"
                />
              </div>
            </.card>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
