defmodule FluxValeWeb.CatalogLive.Deploy do
  @moduledoc """
  The deploy stepper (#74): pick AppVersion → env vars (schema-rendered,
  #70) → resources (#180) → name → Instance. One
  `AshPhoenix.Form.for_create/4` carries the whole flow (ADR-0002:
  forms straight onto resources); steps are UI state, not separate
  forms. The version steps carry ADR-0028's live $X.XX/mo estimate.

  The resources step (#180): CPU/memory/storage default to the
  version's recommended allocation (its defaults, kept equal to
  `recommended_size` by ValidateSizeMatchesAllocation). Above the
  recommendation is unrestricted; below shows a heads-up ("it may run
  slowly or fail") and requires an explicit acknowledgment before
  Continue proceeds — a wizard-level gate, mirroring the env step's
  client-controlled order (the platform's own guardrails are the
  Instance attribute floors, enforced regardless of acknowledgment).

  The allocation is **selected, never typed** (#195, owner feedback):
  the seeded `Size` rows are quick-pick buttons and each dimension has
  a stepped slider bounded by the platform's own range and snapped to a
  fixed granularity (`resource_dimensions/0`). No text control renders
  on this step. Every allocation a *user* can reach is a ladder value
  by construction (`initial_resources/1` snaps the version default,
  `preset_sizes/1` filters the picks to representable sizes, and a
  range input only ever emits ladder values); the parse and the
  floor/ceiling checks below stay the authoritative say for a crafted
  event.

  Pricing follows the allocation (#186): at the recommendation the
  estimate is the version's recommended-size price; a custom
  allocation prices by the anchor formula (ADR-0028's
  price = f(allocation), docs/pricing-calibration.md) — the same cents
  the ledger snapshots at create, so the shown price is the charged
  price by construction.

  Submit = `create` → `deploy` → the instance's status page — matching
  the M3 exit demo. Schema defaults are merged server-side
  (DeriveFromAppVersion), so only user-set values ride the form; empty
  inputs are dropped rather than overriding a default with "". Step
  transitions validate only the fields that step owns — :name's absence
  must not bounce the env step.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing.Size

  # The sliders' bounds and snap (#195): the platform's own ceilings on
  # the max (the Instance attribute constraints) and the smallest
  # allocation the wizard sells on the min, at a fixed granularity.
  # Every seeded size lands exactly on all three ladders
  # (0.25 / 128 / 5 divide micro…pro) — a test pins that — and every
  # value the step renders is snapped to a ladder value (see
  # initial_resources/1, preset_sizes/1), so an off-ladder allocation
  # can never reach a range input and get rounded under the state's
  # feet. Values below the min stay legal at the API (the resource
  # floors are enforced there, unchanged); this step just never offers
  # them.
  defp resource_dimensions do
    [
      %{
        key: "cpu_cores",
        id: "resource-cpu-cores",
        label: "CPU cores",
        testid: "resource-cpu",
        min: "0.25",
        max: "64",
        step: "0.25",
        unit: "cores"
      },
      %{
        key: "memory_mb",
        id: "resource-memory-mb",
        label: "Memory",
        testid: "resource-memory",
        min: "128",
        max: "65536",
        step: "128",
        unit: "MB"
      },
      %{
        key: "storage_gb",
        id: "resource-storage-gb",
        label: "Storage",
        testid: "resource-storage",
        min: "0",
        max: "10240",
        step: "5",
        unit: "GB"
      }
    ]
  end

  @impl Phoenix.LiveView
  def mount(%{"slug" => slug}, _session, socket) do
    user = socket.assigns.current_user

    case Catalog.App.get_by_slug(slug, actor: user) do
      {:ok, app} ->
        app = Ash.load!(app, [app_versions: :recommended_size], actor: user)
        versions = Enum.sort_by(app.app_versions, & &1.version, :desc)

        socket =
          socket
          |> assign(app: app, versions: versions)
          |> assign(step: 1, version_id: nil, selected: nil, env_values: %{}, schema: %{})
          |> assign(resources: nil, below_recommendation?: false, below_ack: false)
          |> assign(resource_errors: [])
          |> assign(:pricing_sizes, preset_sizes(user))
          |> assign(
            :form,
            Instance
            |> AshPhoenix.Form.for_create(:create, actor: user, as: "instance")
            |> to_form()
          )

        {:ok, socket}

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "App not found.")
         |> push_navigate(to: ~p"/apps")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    # The quick-pick rows carry their own pressed/recommended state —
    # `aria-pressed` is a string attribute (a bare boolean renders as an
    # empty value and announces nothing), and the allocation parses once
    # per size instead of twice.
    assigns = assign(assigns, :presets, preset_options(assigns))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-2xl mx-auto space-y-8">
        <div>
          <.button variant="ghost" size="sm" navigate={~p"/apps/#{@app.slug}"} class="-ml-2 mb-4">
            &larr; {@app.name}
          </.button>
          <h1 class="text-2xl font-semibold tracking-tight text-ink">Deploy {@app.name}</h1>
        </div>

        <.stepper
          steps={[
            {"version", "Version"},
            {"configuration", "Configuration"},
            {"resources", "Resources"},
            {"name", "Name"}
          ]}
          current={@step - 1}
        />

        <.card :if={@step == 1} class="space-y-4">
          <h2 class="text-base font-medium text-ink">Pick a version</h2>
          <div class="space-y-2">
            <label
              :for={version <- @versions}
              for={"version-#{version.id}"}
              class="flex cursor-pointer items-center gap-3 rounded-lg px-3 py-2 transition-colors hover:bg-panel-raised"
            >
              <input
                type="radio"
                name="version_id"
                id={"version-#{version.id}"}
                value={version.id}
                checked={@version_id == version.id}
                phx-click="pick-version"
                phx-value-id={version.id}
                class="size-4 accent-primary"
                data-testid="version-option"
              />
              <span class="text-sm text-ink">
                <span class="font-mono">v{version.version}</span>
                <span :if={version.published_at} class="ml-1 text-xs text-ink-subtle">
                  published {Calendar.strftime(version.published_at, "%b %d, %Y")}
                </span>
                <span
                  :if={version.recommended_size}
                  class="ml-1 text-xs text-ink-subtle"
                  data-testid={"version-price-#{version.version}"}
                >
                  {FluxVale.Pricing.format_usd(version.recommended_size.monthly_cents)}/mo
                </span>
              </span>
            </label>
          </div>
          <div class="flex justify-end">
            <.button
              size="sm"
              phx-click="to-env"
              disabled={is_nil(@version_id)}
              data-testid="continue-version"
            >
              Continue
            </.button>
          </div>
        </.card>

        <.card :if={@step == 2} class="max-w-lg space-y-4">
          <h2 class="text-base font-medium text-ink">Configuration</h2>

          <ul
            :if={env_errors(@form) != []}
            id="env-errors"
            class="space-y-1 text-sm text-danger"
          >
            <li :for={msg <- env_errors(@form)}>{msg}</li>
          </ul>

          <p :if={@schema == []} class="text-sm text-ink-muted">
            Nothing to configure for this app — continue.
          </p>

          <form
            :if={@schema != []}
            id="env-form"
            phx-submit="env-continue"
            class="space-y-4"
          >
            <div :for={{name, spec} <- @schema}>
              <label class="mb-1.5 block text-sm font-medium text-ink" for={"env-#{name}"}>
                {spec.label}
                <span :if={spec.required} class="text-danger">*</span>
                <span class="ml-1 font-mono text-xs text-ink-subtle">{name}</span>
              </label>
              <.env_input
                name={"env_values[#{name}]"}
                id={"env-#{name}"}
                spec={spec}
                value={Map.get(@env_values, name)}
              />
              <p :if={spec.description} class="mt-1.5 text-xs text-ink-subtle">
                {spec.description}
              </p>
            </div>
            <div class="flex justify-end gap-3 pt-2">
              <.button variant="ghost" size="sm" type="button" phx-click="back-version">
                Back
              </.button>
              <.button type="submit" size="sm" data-testid="continue-env">
                Continue
              </.button>
            </div>
          </form>

          <div :if={@schema == []} class="flex justify-end gap-3">
            <.button variant="ghost" size="sm" type="button" phx-click="back-version">
              Back
            </.button>
            <.button type="button" size="sm" phx-click="env-continue" data-testid="continue-env">
              Continue
            </.button>
          </div>
        </.card>

        <.card :if={@step == 3} class="space-y-4">
          <h2 class="text-base font-medium text-ink">Resources</h2>

          <p class="text-sm text-ink-muted">
            {@app.name} recommends
            <span
              class="font-mono text-ink"
              data-testid="recommended-allocation"
            >
              {@selected.default_cpu_cores} CPU · {@selected.default_memory_mb} MB · {@selected.default_storage_gb} GB
            </span>
            for this version — allocate more, or less at your own risk.
          </p>

          <ul
            :if={@resource_errors != []}
            id="resource-errors"
            class="space-y-1 text-sm text-danger"
          >
            <li :for={msg <- @resource_errors}>{msg}</li>
          </ul>

          <form
            id="resources-form"
            phx-change="resources-change"
            phx-submit="resources-continue"
            class="space-y-5"
          >
            <div class="space-y-2">
              <p class="text-sm font-medium text-ink" id="quick-picks-label">Quick picks</p>
              <div
                class="grid gap-2 sm:grid-cols-2"
                role="group"
                aria-labelledby="quick-picks-label"
              >
                <button
                  :for={preset <- @presets}
                  type="button"
                  id={"preset-#{preset.slug}"}
                  phx-click="pick-size"
                  phx-value-slug={preset.slug}
                  aria-pressed={preset.pressed}
                  data-testid={"preset-#{preset.slug}"}
                  class={[
                    "flex items-center justify-between gap-3 rounded-lg border px-3 py-2 text-left transition-colors",
                    "outline-offset-2 outline-focus focus-visible:outline-2",
                    if(preset.pressed == "true",
                      do: "border-primary bg-primary-muted",
                      else: "border-line bg-panel hover:border-line-strong hover:bg-panel-raised"
                    )
                  ]}
                >
                  <span class="min-w-0">
                    <span class="block text-sm font-medium text-ink capitalize">
                      {preset.slug}
                      <span
                        :if={preset.recommended}
                        class="ml-1 align-middle rounded-full bg-primary-muted px-1.5 py-0.5 text-[0.6875rem] font-normal text-primary"
                      >
                        recommended
                      </span>
                    </span>
                    <span class="block truncate font-mono text-xs text-ink-muted">
                      {preset.allocation}
                    </span>
                  </span>
                  <span class="flex-none text-sm font-semibold text-ink">
                    {preset.price}/mo
                  </span>
                </button>
              </div>
            </div>

            <div class="space-y-4 border-t border-line pt-5">
              <p class="text-sm font-medium text-ink">Fine-tune</p>
              <.slider
                :for={dimension <- resource_dimensions()}
                id={dimension.id}
                name={"resources[#{dimension.key}]"}
                label={dimension.label}
                value={@resources[dimension.key]}
                min={dimension.min}
                max={dimension.max}
                step={dimension.step}
                unit={dimension.unit}
                data-testid={dimension.testid}
              />
            </div>

            <.callout
              :if={@below_recommendation?}
              id="below-recommendation-warning"
              tone="warning"
              role="alert"
              data-testid="below-recommendation-warning"
            >
              <p class="font-medium text-ink">
                This is below what {@app.name} recommends — it may run slowly or fail.
              </p>
              <label
                for="below-recommendation-ack"
                class="flex cursor-pointer items-center gap-3 pt-2 text-sm text-ink"
              >
                <input
                  type="checkbox"
                  name="resources[below_ack]"
                  id="below-recommendation-ack"
                  checked={@below_ack}
                  class="size-4 accent-warning"
                  data-testid="below-recommendation-ack"
                /> I understand — deploy with less than the recommended resources
              </label>
            </.callout>

            <div
              class="flex flex-wrap items-center justify-between gap-4 rounded-xl bg-panel-raised px-4 py-3 text-sm"
              data-testid="resources-price"
            >
              <span class="text-ink">
                {@app.name} <span class="font-mono">v{@selected.version}</span>
                <span :if={@resources} class="text-ink-muted">
                  · {allocation_text(@resources)}
                </span>
              </span>
              <.price_line selected={@selected} resources={@resources} />
            </div>

            <div class="flex justify-end gap-3 pt-2">
              <.button variant="ghost" size="sm" type="button" phx-click="back-env">
                Back
              </.button>
              <.button
                type="submit"
                size="sm"
                disabled={@below_recommendation? and not @below_ack}
                data-testid="continue-resources"
              >
                Continue
              </.button>
            </div>
          </form>
        </.card>

        <.card :if={@step == 4} class="space-y-4">
          <h2 class="text-base font-medium text-ink">Name your instance</h2>
          <div
            :if={@selected}
            class="flex flex-wrap items-center justify-between gap-4 rounded-xl bg-panel-raised px-4 py-3 text-sm"
            data-testid="price-summary"
          >
            <span class="text-ink">
              {@app.name} <span class="font-mono">v{@selected.version}</span>
              <span :if={@resources} class="text-ink-muted">
                · {allocation_text(@resources)}
              </span>
            </span>
            <.price_line selected={@selected} resources={@resources} />
          </div>
          <ul
            :if={step_invisible_errors(@form) != []}
            id="deploy-errors"
            class="space-y-1 text-sm text-danger"
          >
            <li :for={msg <- step_invisible_errors(@form)}>{msg}</li>
          </ul>
          <.form for={@form} id="deploy-form" phx-submit="save" class="space-y-4">
            <.input
              field={@form[:name]}
              type="text"
              label="Instance name"
              placeholder={"My #{@app.name}"}
              required
              autofocus
              data-testid="instance-name"
            />
            <p class="text-xs text-ink-subtle">
              We'll generate the subdomain — the name is yours to change later, nothing else.
            </p>
            <div class="flex justify-end gap-3 pt-2">
              <.button variant="ghost" size="sm" type="button" phx-click="back-resources">
                Back
              </.button>
              <.button
                type="submit"
                phx-disable-with="Deploying…"
                data-testid="deploy-submit"
              >
                Deploy {@app.name}
              </.button>
            </div>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  # The price line is one component so the resources step and the name
  # step can't disagree. The estimate follows the allocation (#186): at
  # the recommendation it is the version's size price; a custom
  # allocation prices by the anchor formula — the same cents the ledger
  # snapshots at create, so the shown price is the charged price by
  # construction. An unparseable allocation (only reachable via a
  # crafted event since #195) parses to no price: the line waits for a
  # number rather than guessing.
  defp price_line(%{selected: selected, resources: resources} = assigns) do
    at_recommendation = recommendation?(selected, resources)

    assigns =
      assign(assigns,
        size: selected.recommended_size,
        at_recommendation: at_recommendation,
        custom_cents: custom_allocation_cents(resources, at_recommendation)
      )

    ~H"""
    <span :if={@size && @at_recommendation} class="font-semibold text-ink">
      {FluxVale.Pricing.format_usd(@size.monthly_cents)}/mo
    </span>
    <span :if={not @at_recommendation and not is_nil(@custom_cents)} class="font-semibold text-ink">
      {FluxVale.Pricing.format_usd(@custom_cents)}/mo
    </span>
    """
  end

  defp custom_allocation_cents(_resources, true), do: nil

  defp custom_allocation_cents(resources, false) do
    case parse_allocation(resources) do
      {:ok, allocation} ->
        rates = FluxVale.Pricing.price_allocation(allocation)
        rates.monthly_cents

      {:error, _errors} ->
        nil
    end
  end

  # The env surface is a map attribute, not a nested form: plain fields
  # under env_values[NAME] arrive as a map on submit. Values are strings
  # end to end (the K8s Secret's exact contents). Controls ride the
  # system's <.input> (no form field — name/value/explicit attrs, #178
  # wave 2); the label + description stay bespoke (spec metadata).
  defp env_input(%{spec: %{type: :boolean}} = assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type="select"
      options={[{"true", "true"}, {"false", "false"}]}
      value={value(@spec, @value)}
      class="max-w-xs"
    />
    """
  end

  defp env_input(%{spec: %{type: :integer}} = assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type="number"
      step="1"
      value={value(@spec, @value)}
      class="max-w-xs"
    />
    """
  end

  defp env_input(assigns) do
    ~H"""
    <.input
      id={@id}
      name={@name}
      type={input_type(@spec)}
      value={value(@spec, @value)}
      class="max-w-xs"
    />
    """
  end

  defp value(_spec, value) when is_binary(value), do: value
  defp value(spec, nil), do: spec.default && to_string(spec.default)

  defp input_type(%{secret: true}), do: "password"
  defp input_type(_spec), do: "text"

  defp env_errors(form) do
    form
    |> AshPhoenix.Form.errors(format: :simple)
    |> Keyword.get_values(:env_vars)
  end

  # Everything the create can reject that the name step renders no
  # input for (#175): :name errors already show on its own input, and
  # :env_vars/:app_version_id bounce back to their steps — the rest
  # (Oct 20's shape: a missing Cluster row erroring on :cluster_id)
  # used to vanish entirely.
  defp step_invisible_errors(form) do
    form
    |> AshPhoenix.Form.errors(format: :simple)
    |> Keyword.drop([:name, :env_vars, :app_version_id])
    |> Keyword.values()
  end

  @impl Phoenix.LiveView
  def handle_event("pick-version", %{"id" => id}, socket) do
    {:noreply, assign(socket, :version_id, id)}
  end

  def handle_event("to-env", _params, socket) do
    # The Continue button's disabled state is client-side only — a
    # channel-level "to-env" (or a pick of an id not in @versions)
    # must not crash on the nil lookup. Stay on the version step.
    case selected_version(socket) do
      nil ->
        {:noreply,
         socket
         |> assign(:step, 1)
         |> put_flash(:error, "Pick a version first.")}

      version ->
        socket =
          socket
          |> assign(step: 2, schema: sorted_schema(version), selected: version)
          |> validate_step(%{"app_version_id" => version.id})

        {:noreply, socket}
    end
  end

  def handle_event("back-version", _params, socket) do
    {:noreply, assign(socket, step: 1)}
  end

  def handle_event("env-continue", params, socket) do
    # Crafted before a version is picked: no recommendation to default
    # from (to-env's guard posture — the event can't skip ahead).
    if is_nil(socket.assigns.selected) do
      {:noreply,
       socket
       |> assign(:step, 1)
       |> put_flash(:error, "Pick a version first.")}
    else
      env_continue(params, socket)
    end
  end

  def handle_event("back-env", _params, socket) do
    {:noreply, assign(socket, step: 2)}
  end

  # Live: every slider move or preset pick re-renders the
  # below-recommendation warning and keeps the ack coherent (a change
  # that leaves the recommendation band drops a stale ack). Floor errors
  # don't fire here — a partial state must not flash errors; they gate
  # at continue, and again at the form cast on save.
  def handle_event("resources-change", %{"resources" => params}, socket) do
    # Crafted events before a version is picked must not crash on the
    # nil selected version (same posture as to-env's guard); the
    # resources step's own inputs can't fire before it renders.
    if socket.assigns.selected do
      resources = merged_resources(socket, params)

      {:noreply, assign_resource_state(socket, resources, acked?(params))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("resources-continue", %{"resources" => params}, socket) do
    if socket.assigns.selected do
      resources_continue(params, socket)
    else
      {:noreply, put_flash(socket, :error, "Pick a version first.")}
    end
  end

  def handle_event("back-resources", _params, socket) do
    # Step 3 renders the selected version — crafted from before a pick
    # there is nothing to render (to-env's guard posture). A genuine
    # back-nav carries the allocation the env gate set; a crafted one
    # before it gets the recommendation, so the step always renders a
    # full control set (#195) instead of a nil-valued one.
    if socket.assigns.selected do
      resources = socket.assigns.resources || initial_resources(socket.assigns.selected)

      socket =
        socket
        |> assign_resource_state(resources, socket.assigns.below_ack)
        |> assign(:step, 3)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # A quick pick (#195): the seeded size's whole allocation at once —
  # the same state a slider round trip would reach, priced from the
  # Size row (its allocation is the recommendation-shaped point on the
  # curve). The ack starts cold: switching allocation always earns a
  # fresh look at the heads-up, and a preset that lands at or above the
  # recommendation never mounts one.
  def handle_event("pick-size", %{"slug" => slug}, socket) do
    if socket.assigns.selected do
      case Enum.find(socket.assigns.pricing_sizes, &(&1.slug == slug)) do
        nil ->
          # A crafted slug (or a size deleted mid-step): the rendered
          # buttons can't produce one. Nothing to read, nothing changes.
          {:noreply, socket}

        size ->
          socket = assign_resource_state(socket, size_resources(size), false)
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", %{"instance" => instance_params}, socket) do
    params =
      socket.assigns.form.params
      |> Map.merge(instance_params)
      |> Map.put("env_vars", socket.assigns.env_values)
      |> Map.merge(allocation_params(socket.assigns.resources))

    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, instance} ->
        # Auto-deploy: the stepper's exit is the status page already
        # moving (pending → deploying). The instance page's Deploy
        # button covers the pending/error retry states.
        deploying = Instance.deploy!(instance, actor: socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "Deploying #{deploying.slug} — tracking its progress.")
         |> push_navigate(to: ~p"/instances/#{deploying.id}")}

      {:error, form} ->
        socket =
          socket
          |> assign(:form, form)
          |> put_flash(:error, "Fix the errors above.")

        # An env error surfacing only at submit (e.g. the schema changed
        # under the stepper) would be invisible on the name step.
        {:noreply, maybe_back_to_env(socket, form)}
    end
  end

  defp maybe_back_to_env(socket, form) do
    if step_errors?(form, [:env_vars, :app_version_id]) do
      assign(socket, :step, 2)
    else
      socket
    end
  end

  defp env_continue(params, socket) do
    env_values = drop_empty(params["env_values"] || %{})

    # A back-nav round trip keeps the chosen allocation (env values
    # persist the same way); the ack always starts cold — the warning
    # deserves a fresh look after any detour.
    resources = socket.assigns.resources || initial_resources(socket.assigns.selected)

    socket =
      socket
      |> assign(env_values: env_values, step: 3)
      |> assign_resource_state(resources, false)
      |> validate_step(%{"env_vars" => env_values})

    if step_errors?(socket.assigns.form, [:env_vars, :app_version_id]) do
      socket =
        socket
        |> assign(:step, 2)
        |> put_flash(:error, "Fix the configuration errors below.")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp resources_continue(params, socket) do
    resources = merged_resources(socket, params)
    socket = assign_resource_state(socket, resources, acked?(params))
    errors = allocation_errors(socket.assigns.resources)

    cond do
      errors != [] ->
        {:noreply,
         socket
         |> assign(:resource_errors, errors)
         |> put_flash(:error, "Fix the resource errors below.")}

      socket.assigns.below_recommendation? and not socket.assigns.below_ack ->
        # The disabled button is client-side only — the server-side gate
        # holds for a crafted event (same posture as to-env).
        {:noreply, put_flash(socket, :error, "Acknowledge the below-recommendation warning.")}

      true ->
        socket =
          socket
          |> validate_step(allocation_params(socket.assigns.resources))
          |> assign(:step, 4)

        {:noreply, socket}
    end
  end

  defp step_errors?(form, fields) do
    errors = AshPhoenix.Form.errors(form, format: :simple)
    Enum.any?(fields, &Keyword.has_key?(errors, &1))
  end

  defp validate_step(socket, extra_params) do
    params = Map.merge(socket.assigns.form.params, extra_params)
    assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))
  end

  defp drop_empty(env_values) do
    env_values
    |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp sorted_schema(version) do
    Enum.sort_by(version.configurable_env_vars, fn {_name, spec} -> spec.label end)
  end

  defp selected_version(socket) do
    Enum.find(socket.assigns.versions, &(&1.id == socket.assigns.version_id))
  end

  # --- Resources step (#180) ------------------------------------------------
  # Input state is strings end to end (the sliders' exact values);
  # parsing happens at the edges — here for warnings, at
  # resources-continue for floor errors, at the form cast for the
  # authoritative say.

  # The quick picks (#195): the seeded Sizes, cheapest first — business
  # data (admin-editable, ADR-0027), read once at mount like the rest of
  # the catalog, so an edit lands on the next visit rather than under a
  # wizard already open. Reads are actor-scoped like every other catalog
  # surface. Sizes the sliders can't represent (an admin allocation off
  # the ladder or past a bound) are omitted: a quick pick that its own
  # wizard would refuse or silently clamp is worse than no pick at all.
  defp preset_sizes(user) do
    Size
    |> Ash.Query.for_read(:read, %{}, actor: user)
    |> Ash.Query.sort(monthly_cents: :asc)
    |> Ash.read!()
    |> Enum.filter(&representable_size?/1)
  end

  defp representable_size?(size) do
    Decimal.eq?(size.cpu_cores, snap_decimal(size.cpu_cores, "0.25", "0.25", "64")) and
      size.memory_mb == snap_integer(size.memory_mb, 128, 128, 65_536) and
      size.storage_gb == snap_integer(size.storage_gb, 0, 5, 10_240)
  end

  defp size_resources(size) do
    %{
      "cpu_cores" => decimal_string(size.cpu_cores),
      "memory_mb" => Integer.to_string(size.memory_mb),
      "storage_gb" => Integer.to_string(size.storage_gb)
    }
  end

  defp size_allocation(size) do
    "#{decimal_string(size.cpu_cores)} CPU · #{size.memory_mb} MB · #{size.storage_gb} GB"
  end

  # One row per seeded size, resolved once for the template: the slug,
  # the allocation and price it carries, whether it is the version's
  # recommendation, and whether the current allocation IS the size
  # (`aria-pressed` — a string, not a bare boolean, so a screen reader
  # hears the state).
  defp preset_options(assigns) do
    for size <- assigns.pricing_sizes do
      %{
        slug: size.slug,
        allocation: size_allocation(size),
        price: FluxVale.Pricing.format_usd(size.monthly_cents),
        recommended: recommended_preset?(assigns.selected, size),
        pressed: to_string(preset_active?(assigns.resources, size))
      }
    end
  end

  defp recommended_preset?(version, size) do
    not is_nil(version) and not is_nil(version.recommended_size) and
      version.recommended_size.slug == size.slug
  end

  # A preset reads as pressed only when the allocation IS the size —
  # same comparison the recommendation check makes, so a repriced or
  # re-allocated size row degrades to "nothing pressed" instead of
  # lying. A nil allocation (any render before the resources step
  # assigns one) is nothing pressed; an unparseable allocation (a
  # crafted change event) likewise.
  defp preset_active?(nil, _size), do: false

  defp preset_active?(resources, size) do
    case parse_allocation(resources) do
      {:ok, allocation} ->
        Decimal.eq?(allocation.cpu_cores, size.cpu_cores) and
          allocation.memory_mb == size.memory_mb and
          allocation.storage_gb == size.storage_gb

      {:error, _errors} ->
        false
    end
  end

  defp initial_resources(version) do
    cpu = snap_decimal(version.default_cpu_cores, "0.25", "0.25", "64")
    memory = snap_integer(version.default_memory_mb, 128, 128, 65_536)
    storage = snap_integer(version.default_storage_gb, 0, 5, 10_240)

    %{
      "cpu_cores" => decimal_string(cpu),
      "memory_mb" => Integer.to_string(memory),
      "storage_gb" => Integer.to_string(storage)
    }
  end

  # A value on its dimension's ladder, always: the nearest multiple of
  # `step`, clamped to the bounds. A range input snaps an off-ladder
  # value in the browser the moment it renders, so an admin-entered
  # version default (ADR-0027 permits allocations the ladders can't
  # express) would otherwise show one number and submit another — the
  # shown price forking from the charge. Snapping here keeps state,
  # readout, thumb and submit one value; a snap that lands below the
  # recommendation correctly reads as below it.
  defp snap_decimal(value, step, min, max) do
    value
    |> Decimal.div(Decimal.new(step))
    |> Decimal.round(0, :half_up)
    |> Decimal.mult(Decimal.new(step))
    |> clamp_decimal(Decimal.new(min), Decimal.new(max))
    |> Decimal.normalize()
  end

  # A snapped Decimal as a form value: normalized (so 0.50 and 0.5 are
  # one number) and expanded (predicate-form normalizing lowercases the
  # exponent, so `normalize(10)` is 1E+1 — never a valid range value).
  defp decimal_string(value), do: Decimal.to_string(value, :normal)

  defp clamp_decimal(value, min, max) do
    cond do
      Decimal.compare(value, min) == :lt -> min
      Decimal.compare(value, max) == :gt -> max
      true -> value
    end
  end

  # Integer dimension (memory/storage): offset from the floor, so a
  # nonzero floor keeps every ladder value reachable.
  defp snap_integer(value, min, step, max) do
    snapped = min + round((value - min) / step) * step
    clamped_low = max(snapped, min)
    min(clamped_low, max)
  end

  # Partial params merge over the current state — or the
  # recommendation when no allocation state exists yet (a crafted
  # event between the version and env gates), so the parsers always
  # see all three strings.
  defp merged_resources(socket, params) do
    base = socket.assigns.resources || initial_resources(socket.assigns.selected)
    Map.merge(base, resource_strings(params))
  end

  # Only the keys this LiveView renders, only strings (the inputs'
  # format) — inside a map-shaped payload a crafted change event can't
  # smuggle extra state in or a non-string that would crash the
  # parsers. A non-map payload is a malformed event like any other
  # unmatched shape (save without "instance" — main's posture).
  # Absent keys carry no opinion (a browser sends every input;
  # LiveViewTest sends the ones under test), so the caller merges over
  # the current state.
  defp resource_strings(params) do
    keys = ~w(cpu_cores memory_mb storage_gb)

    keys
    |> Map.new(fn key -> {key, Map.get(params, key)} end)
    |> Map.reject(fn {_key, value} -> not is_binary(value) end)
  end

  # The checkbox rides the form's phx-change; its presence is the state.
  defp acked?(params), do: Map.has_key?(params, "below_ack")

  defp assign_resource_state(socket, resources, acked) do
    version = socket.assigns.selected
    below? = below_recommendation?(resources, version)

    socket
    |> assign(:resources, resources)
    |> assign(:below_recommendation?, below?)
    |> assign(:below_ack, acked and below?)
    |> assign(:resource_errors, [])
  end

  # Below the recommendation: any dimension strictly under the version's
  # default. Unparseable input can't be assessed for below-ness — it
  # only errors (at continue).
  defp below_recommendation?(resources, version) do
    case parse_allocation(resources) do
      {:ok, allocation} ->
        Decimal.compare(allocation.cpu_cores, version.default_cpu_cores) == :lt or
          allocation.memory_mb < version.default_memory_mb or
          allocation.storage_gb < version.default_storage_gb

      {:error, _errors} ->
        false
    end
  end

  # Hard floors (the Instance attribute constraints): cpu > 0,
  # memory ≥ 1 MB — legal-allocation bounds mirroring Size's own, not
  # UX. They block regardless of acknowledgment. Everything that would
  # crash the curve (negatives, over-DBL_MAX decimals, >308-digit
  # integers) and every numeric ceiling is rejected at the parse —
  # the preview prices on every keystroke, so the parse owns input
  # safety; these floors are the continue-level product rules.
  defp allocation_errors(resources) do
    case parse_allocation(resources) do
      {:ok, allocation} ->
        checks = [
          {Decimal.compare(allocation.cpu_cores, 0) != :gt, "CPU cores must be greater than 0"},
          {allocation.memory_mb < 1, "Memory must be at least 1 MB"}
        ]

        keep_errors(checks)

      {:error, errors} ->
        errors
    end
  end

  defp keep_errors(checks) do
    checks
    |> Enum.filter(fn {fails?, _msg} -> fails? end)
    |> Enum.map(fn {_fails?, msg} -> msg end)
  end

  defp parse_allocation(resources) do
    with {:ok, cpu} <- parse_decimal(resources["cpu_cores"]),
         {:ok, memory} <-
           parse_bounded_integer(
             resources["memory_mb"],
             65_536,
             "Memory must be at most 65536 MB"
           ),
         {:ok, storage} <-
           parse_bounded_integer(
             resources["storage_gb"],
             10_240,
             "Storage must be at most 10240 GB"
           ) do
      {:ok, %{cpu_cores: cpu, memory_mb: memory, storage_gb: storage}}
    end
  end

  defp parse_decimal(raw) do
    case Decimal.parse(raw) do
      {value, ""} ->
        # Ash's own cast rejects non-finite decimals — the preview must
        # not be looser than the authoritative say (NaN would crash
        # every compare; Infinity would walk straight past the floors).
        # Negatives and over-DBL_MAX magnitudes crash :math.pow /
        # Decimal.to_float in the curve, and a negative IS under the
        # floor / over the ceiling, so the parse owns those rejections.
        cond do
          Decimal.nan?(value) or Decimal.inf?(value) ->
            {:error, ["CPU cores must be a number"]}

          Decimal.compare(value, 0) == :lt ->
            {:error, ["CPU cores must be greater than 0"]}

          Decimal.compare(value, Decimal.new(64)) == :gt ->
            {:error, ["CPU cores must be at most 64"]}

          true ->
            {:ok, value}
        end

      _other ->
        {:error, ["CPU cores must be a number"]}
    end
  end

  defp parse_integer(raw) do
    case Integer.parse(raw) do
      {value, ""} ->
        # Negative memory/storage would crash the curve's fractional
        # exponent (:math.pow on a negative base); the floor-specific
        # messages fire at continue for zero.
        if value < 0 do
          {:error, ["Memory and storage cannot be negative"]}
        else
          {:ok, value}
        end

      _other ->
        {:error, ["Memory and storage must be whole numbers"]}
    end
  end

  # The integer ceilings: a >308-digit integer crashes the float
  # division in the curve (the preview prices on every keystroke), and
  # the ceiling is the resource constraint anyway — the parse owns it.
  defp parse_bounded_integer(raw, ceiling, message) do
    case parse_integer(raw) do
      {:ok, value} when value > ceiling -> {:error, [message]}
      parsed -> parsed
    end
  end

  # The allocation as form params — strings, cast by the form the same
  # way the save path would cast them.
  defp allocation_params(nil), do: %{}

  defp allocation_params(resources) do
    %{
      "cpu_cores" => resources["cpu_cores"],
      "memory_mb" => resources["memory_mb"],
      "storage_gb" => resources["storage_gb"]
    }
  end

  # nil resources (a channel-level save or crafted nav from before the
  # resources step) read as the recommendation: the derive applies the
  # version defaults. #195 made step 3 assign an allocation on every
  # way in, so no render reaches this — the clause stays as the
  # defensive say for a nil that would otherwise crash the parse.
  # coveralls-ignore-next-line — defensive: both step-3 entries assign resources first
  defp recommendation?(_version, nil), do: true

  defp recommendation?(version, resources) do
    case parse_allocation(resources) do
      {:ok, allocation} ->
        Decimal.eq?(allocation.cpu_cores, version.default_cpu_cores) and
          allocation.memory_mb == version.default_memory_mb and
          allocation.storage_gb == version.default_storage_gb

      {:error, _errors} ->
        false
    end
  end

  defp allocation_text(resources) do
    "#{resources["cpu_cores"]} CPU · #{resources["memory_mb"]} MB · #{resources["storage_gb"]} GB"
  end
end
