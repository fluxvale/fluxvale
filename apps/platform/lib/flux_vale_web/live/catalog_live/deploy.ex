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
  Instance attribute constraints, enforced regardless of acknowledgment).

  The allocation is **selected, never typed** (#195) and **rungs-only**
  (#221, the owner's call closing #195's control-shape question): the
  seeded `Size` rows are quick-pick buttons and each dimension's slider
  steps through that ladder's rungs — index-based
  (`resource_dimensions/0`), so one arrow press is one rung and the
  thumb never rests between rungs. No text control renders on this
  step, and every allocation the state can hold is a rung by
  construction: `initial_resources/1` floors the version default to
  the next rung at or above it, `preset_sizes/1` filters the picks to
  representable sizes, and `resource_strings/1` maps slider indices
  back to rungs — a crafted index that names no rung is silence, like
  an unknown preset slug. The form cast on save stays the
  authoritative say.

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

  # The sliders' rungs (#221): each dimension's ladder is the seeded
  # Size rows' distinct values for it (micro…max — the same business
  # data the quick picks and pricing carry; top rungs grown on #233),
  # ascending; a test pins the arrays to the seeds. The sliders
  # address rungs by index (a range input can only step uniformly),
  # so the LiveView — not the browser — owns the value arrays. Values
  # outside the ladder stay legal at the API (the Instance attribute
  # constraints, unchanged); this step just never offers them.
  defp resource_dimensions do
    [
      %{
        key: "cpu_cores",
        id: "resource-cpu-cores",
        label: "CPU cores",
        testid: "resource-cpu",
        values: ["0.25", "0.5", "1", "2", "4", "6", "8"],
        unit: "cores"
      },
      %{
        key: "memory_mb",
        id: "resource-memory-mb",
        label: "Memory",
        testid: "resource-memory",
        values: ["512", "1024", "2048", "4096", "8192", "12288", "16384"],
        unit: "MB"
      },
      %{
        key: "storage_gb",
        id: "resource-storage-gb",
        label: "Storage",
        testid: "resource-storage",
        values: ["5", "10", "20", "50", "100", "200", "400"],
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
    <Layouts.app flash={@flash} current_user={@current_user} actor_orgs={@actor_orgs}>
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
                  {FluxVale.Pricing.format_monthly_rate(version.recommended_size.monthly_cents)}
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
                    {preset.price}
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
                values={dimension.values}
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
  # construction.
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
      {FluxVale.Pricing.format_monthly_rate(@size.monthly_cents)}
    </span>
    <span :if={not @at_recommendation and not is_nil(@custom_cents)} class="font-semibold text-ink">
      {FluxVale.Pricing.format_monthly_rate(@custom_cents)}
    </span>
    """
  end

  defp custom_allocation_cents(_resources, true), do: nil

  defp custom_allocation_cents(resources, false) do
    current = allocation(resources)
    rates = FluxVale.Pricing.price_allocation(current)
    rates.monthly_cents
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
  # that leaves the recommendation band drops a stale ack). A crafted
  # index that names no rung is dropped in resource_strings/1, so a
  # partial or hostile payload just keeps the current allocation.
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

    if socket.assigns.below_recommendation? and not socket.assigns.below_ack do
      # The disabled button is client-side only — the server-side gate
      # holds for a crafted event (same posture as to-env).
      {:noreply, put_flash(socket, :error, "Acknowledge the below-recommendation warning.")}
    else
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
  # Input state is rung strings end to end (#221): the sliders emit
  # indices, resource_strings/1 maps them back to rungs, and nothing
  # off-ladder can enter the state. The form cast on save is the
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

  # A quick pick the sliders can state (#221): every dimension value on
  # its ladder — an admin allocation (#221's arrays are the seeds') a
  # rung slider can't express would land as a preset its own wizard
  # refuses or silently clamps: worse than no pick at all, so it stays
  # off the list.
  defp representable_size?(size) do
    size_values = %{
      "cpu_cores" => decimal_string(size.cpu_cores),
      "memory_mb" => Integer.to_string(size.memory_mb),
      "storage_gb" => Integer.to_string(size.storage_gb)
    }

    dimensions = resource_dimensions()

    Enum.all?(dimensions, fn dimension -> size_values[dimension.key] in dimension.values end)
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
        price: FluxVale.Pricing.format_monthly_rate(size.monthly_cents),
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
  # assigns one) is nothing pressed.
  defp preset_active?(nil, _size), do: false

  defp preset_active?(resources, size) do
    current = allocation(resources)

    Decimal.eq?(current.cpu_cores, size.cpu_cores) and
      current.memory_mb == size.memory_mb and
      current.storage_gb == size.storage_gb
  end

  # The app's minimum is the version's defaults (the recommendation).
  # They equal a seeded size's allocation by contract, so they name a
  # rung; when they don't (an admin size the ladder can't express,
  # ADR-0027), the floor still has to be SATISFIABLE: the initial
  # allocation clamps up to the next rung at or above the default, so
  # within the ladder the step never opens under the app's stated
  # minimum. A default PAST the top rung floors to the top rung —
  # which is below the stated minimum, and the heads-up honestly says
  # so: rungs-only simply never offers more (a test pins both).
  defp initial_resources(version) do
    defaults = %{
      "cpu_cores" => decimal_string(version.default_cpu_cores),
      "memory_mb" => Integer.to_string(version.default_memory_mb),
      "storage_gb" => Integer.to_string(version.default_storage_gb)
    }

    dimensions = resource_dimensions()

    Map.new(dimensions, fn dimension ->
      {dimension.key, floor_rung(dimension, defaults[dimension.key])}
    end)
  end

  defp floor_rung(dimension, default) do
    floor = Decimal.new(default)

    at_or_above? = fn value ->
      rung = Decimal.new(value)
      Decimal.compare(rung, floor) != :lt
    end

    dimension.values
    |> Enum.find(at_or_above?)
    |> Kernel.||(List.last(dimension.values))
  end

  # A Decimal as a form value: normalized first (so 0.50, 1.0 and 1
  # are one number — the ladder strings are in shortest form, and both
  # the quick-pick membership check and the sliders' index lookup are
  # string comparisons), then expanded (`:normal` undoes the exponent
  # form normalize lowers to — normalize(10) prints "10", never "1E+1").
  defp decimal_string(value) do
    normalized = Decimal.normalize(value)
    Decimal.to_string(normalized, :normal)
  end

  # Partial params merge over the current state — or the
  # recommendation when no allocation state exists yet (a crafted
  # event between the version and env gates), so every consumer always
  # sees all three rungs.
  defp merged_resources(socket, params) do
    base = socket.assigns.resources || initial_resources(socket.assigns.selected)
    Map.merge(base, resource_strings(params))
  end

  # The sliders' wire format (#221): indices into the dimension's
  # rungs, translated here — only a well-formed index of the
  # dimension's own ladder becomes state, and every other index VALUE
  # (a crafted event: out of range, negative, fractional, non-numeric,
  # a non-string) is silence, exactly like an unknown preset slug. A
  # non-map `resources` payload is a malformed event like any other
  # unmatched shape (save without "instance" — main's posture). Absent
  # keys carry no opinion (a browser sends every input; LiveViewTest
  # sends the ones under test), so the caller merges over the current
  # state.
  defp resource_strings(params) do
    resource_dimensions()
    |> Map.new(fn dimension ->
      {dimension.key, rung_at(dimension, Map.get(params, dimension.key))}
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp rung_at(_dimension, index) when not is_binary(index), do: nil

  defp rung_at(dimension, index) do
    case Integer.parse(index) do
      {i, ""} when i >= 0 -> Enum.at(dimension.values, i)
      _crafted_or_malformed -> nil
    end
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
  end

  # Below the recommendation: any dimension strictly under the version's
  # default.
  defp below_recommendation?(resources, version) do
    current = allocation(resources)

    Decimal.compare(current.cpu_cores, version.default_cpu_cores) == :lt or
      current.memory_mb < version.default_memory_mb or
      current.storage_gb < version.default_storage_gb
  end

  # The typed allocation for the recommendation checks and pricing — a
  # total function since #221: every string the state can hold is a
  # rung, and rungs parse by construction. The form cast on save stays
  # the authoritative say.
  defp allocation(resources) do
    %{
      cpu_cores: Decimal.new(resources["cpu_cores"]),
      memory_mb: String.to_integer(resources["memory_mb"]),
      storage_gb: String.to_integer(resources["storage_gb"])
    }
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
  # defensive say for a nil that would otherwise crash allocation/1.
  # coveralls-ignore-next-line — defensive: both step-3 entries assign resources first
  defp recommendation?(_version, nil), do: true

  defp recommendation?(version, resources) do
    current = allocation(resources)

    Decimal.eq?(current.cpu_cores, version.default_cpu_cores) and
      current.memory_mb == version.default_memory_mb and
      current.storage_gb == version.default_storage_gb
  end

  defp allocation_text(resources) do
    "#{resources["cpu_cores"]} CPU · #{resources["memory_mb"]} MB · #{resources["storage_gb"]} GB"
  end
end
