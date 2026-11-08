defmodule FluxValeWeb.AdminLive.SizeEdit do
  @moduledoc """
  The admin size edit form (#501): the surgery surface over `Size`'s
  own `:update` action.

  Two panels, one action, the freeze made visible: prices (cents) are
  freely editable — prices-as-data is the whole point — while the
  compute controls lock when versions point at the size, with copy
  naming the count and the sanctioned path (re-point or retire first,
  then move the size). The lock is the UI explaining the resource's
  `ValidateAllocationFrozen`, never a bypass: the action-level
  validation stays the enforcement, and an unlocked size's form says
  its compute will freeze once versions point here.

  Prices carry their own consequence copy: an edit reaches running
  instances on this size at their next settle once their first-year
  price lock lapses (the settle's snapshot-then-live semantics,
  `Pricing.settlement_rates/2`). The callout states that unconditionally
  and adds the counts it can see: the Instance read policy narrows to
  the actor's orgs (a filter check, not a forbid), so a platform admin
  with no memberships reads zero rows and the copy never claims a
  global count it cannot see.

  Every write runs through the action with the platform-admin actor and
  `authorize?: true` — the domain policies decide, never the UI.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing.Size
  alias FluxValeWeb.AdminShell

  require Ash.Query

  @price_keys ~w(monthly_cents)

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own data and probe.
    admin = socket.assigns.current_user

    case Ash.get(Size, id, actor: admin, authorize?: true) do
      {:ok, size} ->
        referenced_count = referenced_versions_count(size.id, admin)

        {:ok,
         assign(socket,
           size: size,
           referenced_count: referenced_count,
           price_reach: price_reach(size.id, admin),
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
  # this size. Display-only — the action re-checks on every save, and
  # the failure arms re-probe so a raced write flips the page to the
  # lock instead of contradicting the server.
  defp referenced_versions_count(size_id, admin) do
    AppVersion
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(recommended_size_id == ^size_id)
    |> Ash.count!(actor: admin)
  end

  # The price edit's reach (the settle re-prices past-grace instances
  # at the live Size row, `Pricing.settlement_rates/2`): running
  # instances on this size, split by whether their first-year price
  # lock has lapsed. The read policy narrows to the actor's orgs (a
  # filter check, never a forbid), so these are the counts the actor
  # can actually see — the callout says so instead of passing them off
  # as global. nil on an unexpected read error: the callout keeps the
  # unconditional consequence line.
  defp price_reach(size_id, admin) do
    now = DateTime.utc_now()

    with {:ok, lapsed} <- running_count(size_id, :lapsed, now, admin),
         {:ok, grace} <- running_count(size_id, :grace, now, admin) do
      %{lapsed: lapsed, grace: grace}
    else
      # coveralls-ignore-start - Instance reads filter to the actor's
      # orgs (a filter check, never a forbid), so no policy arm lands
      # here; only a DB-down class error could, and ExUnit cannot
      # simulate one.
      {:error, _error} ->
        nil
        # coveralls-ignore-stop
    end
  end

  # A nil grandfathered_until prices live (the settle's safe default),
  # so it counts as lapsed.
  defp running_count(size_id, :lapsed, now, admin) do
    Instance
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(
      size_id == ^size_id and status == :running and
        (is_nil(grandfathered_until) or grandfathered_until <= ^now)
    )
    |> Ash.count(actor: admin)
  end

  defp running_count(size_id, :grace, now, admin) do
    Instance
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.filter(
      size_id == ^size_id and status == :running and
        (not is_nil(grandfathered_until) and grandfathered_until > ^now)
    )
    |> Ash.count(actor: admin)
  end

  defp build_form(size, admin) do
    size
    |> AshPhoenix.Form.for_update(:update, as: "size", actor: admin, authorize?: true)
    |> to_form()
  end

  # The two-panel split is real, not presentational: the price form
  # only ever submits the cents keys, so an allocation value riding a
  # crafted payload can never move through it.
  defp price_params(%{"size" => params}), do: Map.take(params, @price_keys)
  defp price_params(_params), do: %{}

  @impl Phoenix.LiveView
  def handle_event("validate-price", params, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.price_form, price_params(params))

    {:noreply, assign(socket, price_form: form)}
  end

  def handle_event("save-price", params, socket) do
    params = price_params(params)
    form = AshPhoenix.Form.validate(socket.assigns.price_form, params)

    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, size} ->
        admin = socket.assigns.current_user

        # Re-probe on success: another admin may have pointed a version
        # at this size while the tab was open, and the lock copy must
        # never go stale.
        {:noreply,
         socket
         |> put_flash(:info, gettext("Prices saved."))
         |> assign(
           size: size,
           referenced_count: referenced_versions_count(size.id, admin),
           price_reach: price_reach(size.id, admin),
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
        # The action-level freeze speaking (a raced write most likely):
        # re-probe and let the page render the lock — the card-level
        # consequence, never a field error contradicting the server.
        admin = socket.assigns.current_user

        flash =
          if frozen_rejection?(error_form) do
            gettext(
              "The action rejected the move. This compute is frozen while versions point at it."
            )
          else
            gettext("Could not save the allocation. Check the errors below.")
          end

        {:noreply,
         socket
         |> put_flash(:error, flash)
         |> assign(allocation_form: to_form(error_form))
         |> assign(referenced_count: referenced_versions_count(socket.assigns.size.id, admin))}
    end
  end

  # The validator's own message (untouched logic); matched here only to
  # pick the honest flash. The card-level answer is the lock itself.
  defp frozen_rejection?(error_form) do
    error_form
    |> AshPhoenix.Form.errors(format: :simple)
    |> Enum.any?(fn {_field, message} -> message =~ "frozen" end)
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
      wide
    >
      <%!-- The console lane (#593): `wide` chrome + `appgram console`
      — flush sidebar, the page fills the space beside it. The form
      pair keeps the settings idiom's measure via the grid cap: a
      rate input at viewport width is a ruled line, not a field. --%>
      <div class="appgram console contents" data-testid="admin-size-edit">
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

        <%!-- The section sidebar (Am. 4, the #568 idiom); the size
            edit is a catalog sub-route, so it marks the catalog entry
            as an ancestor (aria-current="location"). The back link
            stays — it is intra-section. --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar
              current="catalog"
              exact={false}
              pending_requests={@pending_storage_requests}
            />

            <div class="min-w-0 flex-1">
              <div class="grid max-w-3xl gap-6 lg:grid-cols-2">
                <%!-- Prices: business data, freely editable — the admin path
            this resource exists for. The consequence callout states the
            reach: past-grace running instances settle at the new rate
            at their next settle. The pair keeps the settings idiom's
            form measure via the grid cap (the people grid's posture).
            --%>
                <.card class="space-y-4" data-testid="admin-size-prices">
                  <div>
                    <h2 class="text-base font-medium text-ink">{gettext("Prices")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      {gettext(
                        "Prices are business data. Edit them freely. The monthly rate prices this compute class. Storage prices per GB on its own axis."
                      )}
                    </p>
                  </div>

                  <.callout
                    tone="warning"
                    title={gettext("This price reaches running instances")}
                    data-testid="admin-size-price-reach"
                  >
                    <div class="space-y-1.5">
                      <p>
                        {gettext(
                          "A price edit reaches running instances on this size at their next settle, once their first-year price lock lapses."
                        )}
                      </p>
                      <p :if={@price_reach && @price_reach.lapsed > 0}>
                        {ngettext(
                          "Visible to your account: 1 running instance already settles at this rate.",
                          "Visible to your account: %{count} running instances already settle at this rate.",
                          @price_reach.lapsed
                        )}
                      </p>
                      <p :if={@price_reach && @price_reach.grace > 0}>
                        {ngettext(
                          "Visible to your account: 1 more is still inside its first-year price lock. It moves to this rate when the lock lapses.",
                          "Visible to your account: %{count} more are still inside their first-year price locks. They move to this rate when the locks lapse.",
                          @price_reach.grace
                        )}
                      </p>
                    </div>
                  </.callout>

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
                    <.button type="submit" data-testid="admin-size-price-save">
                      {gettext("Save prices")}
                    </.button>
                  </.form>
                </.card>

                <%!-- Allocation: the freeze as UI. Locked sizes render
            filled read-only fields behind a Locked chip, with the
            count and the path named in a standard callout — the
            compute shape, not the warning, is the loudest thing here.
            Free sizes render a live form and the note that the freeze
            is one pointing-version away. --%>
                <.card class="space-y-4" data-testid="admin-size-allocation">
                  <div>
                    <h2 class="text-base font-medium text-ink">{gettext("Allocation")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      {gettext("The compute a version's blueprint must match.")}
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
                        "Its compute defaults must keep matching this size. Re-point those versions to another size, or retire them in the debug admin. Then this compute can move."
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
                      {gettext("The compute is editable now. It freezes once a version points here.")}
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
                    <.button type="submit" data-testid="admin-size-alloc-save">
                      {gettext("Save allocation")}
                    </.button>
                  </.form>

                  <div :if={@referenced_count > 0} class="space-y-4">
                    <div class="flex items-center gap-1.5" data-testid="admin-size-locked-chip">
                      <.badge tone="warning">
                        <.icon name="hero-lock-closed" class="size-3.5" />
                        {gettext("Locked")}
                      </.badge>
                    </div>
                    <div data-testid="admin-size-alloc-cpu">
                      <p class="mb-1.5 text-sm font-medium text-ink-muted">{gettext("CPU cores")}</p>
                      <div class="rounded-control border border-line bg-panel-raised px-3 py-2 text-sm text-ink">
                        {alloc_cpu_value(assigns)}
                      </div>
                    </div>
                    <div data-testid="admin-size-alloc-memory">
                      <p class="mb-1.5 text-sm font-medium text-ink-muted">
                        {gettext("Memory (MB)")}
                      </p>
                      <div class="rounded-control border border-line bg-panel-raised px-3 py-2 text-sm text-ink">
                        {@size.memory_mb}
                      </div>
                    </div>
                  </div>
                </.card>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
