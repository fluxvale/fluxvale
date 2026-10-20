defmodule FluxValeWeb.CatalogLive.Deploy do
  @moduledoc """
  The deploy stepper (#74): pick AppVersion → env vars (schema-rendered,
  #70) → resources (#180) → name → Instance. One
  `AshPhoenix.Form.for_create/4` carries the whole flow (ADR-0002:
  forms straight onto resources); steps are UI state, not separate
  forms. The version steps carry ADR-0028's live $X.XX/mo estimate.

  The resources step (#180): CPU/memory/storage controls default to
  the version's recommended allocation (its defaults, kept equal to
  `recommended_size` by ValidateSizeMatchesAllocation). Above the
  recommendation is unrestricted; below shows a heads-up ("it may run
  slowly or fail") and requires an explicit acknowledgment before
  Continue proceeds — a wizard-level gate, mirroring the env step's
  client-controlled order (the platform's own guardrails are the
  Instance attribute floors, enforced regardless of acknowledgment).

  Pricing interim: the estimate still reads the version's recommended
  size — allocation-following pricing (formula vs smooth snap) is an
  open decision (open-questions.md, #180), so until it lands a custom
  allocation is billed at the recommended size and the UI says so.
  That keeps the shown price equal to the ledger's charge by
  construction.

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
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-2xl mx-auto space-y-8">
        <div>
          <.link navigate={~p"/apps/#{@app.slug}"} class="btn btn-ghost btn-sm mb-4">
            &larr; {@app.name}
          </.link>
          <h1 class="text-3xl font-bold tracking-tight">Deploy {@app.name}</h1>
        </div>

        <ul class="steps w-full text-sm">
          <li class="step step-primary">Version</li>
          <li class={["step", @step >= 2 && "step-primary"]}>Configuration</li>
          <li class={["step", @step >= 3 && "step-primary"]}>Resources</li>
          <li class={["step", @step >= 4 && "step-primary"]}>Name</li>
        </ul>

        <div :if={@step == 1} class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Pick a version</h2>
            <div class="form-control gap-2">
              <label
                :for={version <- @versions}
                for={"version-#{version.id}"}
                class="label cursor-pointer justify-start gap-3 rounded-lg px-3 py-2 hover:bg-base-300 transition-colors"
              >
                <input
                  type="radio"
                  name="version_id"
                  id={"version-#{version.id}"}
                  value={version.id}
                  checked={@version_id == version.id}
                  phx-click="pick-version"
                  phx-value-id={version.id}
                  class="radio radio-primary radio-sm"
                  data-testid="version-option"
                />
                <span class="label-text">
                  <span class="font-mono">v{version.version}</span>
                  <span :if={version.published_at} class="opacity-60 text-xs">
                    &nbsp;published {Calendar.strftime(version.published_at, "%b %d, %Y")}
                  </span>
                  <span
                    :if={version.recommended_size}
                    class="opacity-60 text-xs"
                    data-testid={"version-price-#{version.version}"}
                  >
                    &nbsp;{FluxVale.Pricing.format_usd(version.recommended_size.monthly_cents)}/mo
                  </span>
                </span>
              </label>
            </div>
            <div class="card-actions justify-end">
              <button
                type="button"
                phx-click="to-env"
                disabled={is_nil(@version_id)}
                class="btn btn-primary btn-sm"
                data-testid="continue-version"
              >
                Continue
              </button>
            </div>
          </div>
        </div>

        <div :if={@step == 2} class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Configuration</h2>

            <ul
              :if={env_errors(@form) != []}
              id="env-errors"
              class="text-sm text-error space-y-1"
            >
              <li :for={msg <- env_errors(@form)}>{msg}</li>
            </ul>

            <p :if={@schema == []} class="text-sm opacity-70">
              Nothing to configure for this app — continue.
            </p>

            <form
              :if={@schema != []}
              id="env-form"
              phx-submit="env-continue"
              class="space-y-4"
            >
              <div :for={{name, spec} <- @schema} class="form-control">
                <label class="label pb-1" for={"env-#{name}"}>
                  <span class="label-text">
                    {spec.label}
                    <span :if={spec.required} class="text-error">*</span>
                    <span class="opacity-50 font-mono text-xs">&nbsp;{name}</span>
                  </span>
                </label>
                <.env_input
                  name={"env_values[#{name}]"}
                  id={"env-#{name}"}
                  spec={spec}
                  value={Map.get(@env_values, name)}
                />
                <span :if={spec.description} class="label-text-alt opacity-60 pt-1">
                  {spec.description}
                </span>
              </div>
              <div class="card-actions justify-end pt-2">
                <button type="button" phx-click="back-version" class="btn btn-ghost btn-sm">
                  Back
                </button>
                <button type="submit" class="btn btn-primary btn-sm" data-testid="continue-env">
                  Continue
                </button>
              </div>
            </form>

            <div :if={@schema == []} class="card-actions justify-end">
              <button type="button" phx-click="back-version" class="btn btn-ghost btn-sm">
                Back
              </button>
              <button
                type="button"
                phx-click="env-continue"
                class="btn btn-primary btn-sm"
                data-testid="continue-env"
              >
                Continue
              </button>
            </div>
          </div>
        </div>

        <div :if={@step == 3} class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Resources</h2>

            <p class="text-sm opacity-70">
              {@app.name} recommends
              <span class="font-mono" data-testid="recommended-allocation">
                {@selected.default_cpu_cores} CPU · {@selected.default_memory_mb} MB · {@selected.default_storage_gb} GB
              </span>
              — the defaults below. Allocate more, or less at your own risk.
            </p>

            <ul
              :if={@resource_errors != []}
              id="resource-errors"
              class="text-sm text-error space-y-1"
            >
              <li :for={msg <- @resource_errors}>{msg}</li>
            </ul>

            <form
              id="resources-form"
              phx-change="resources-change"
              phx-submit="resources-continue"
              class="space-y-4"
            >
              <div class="grid gap-4 sm:grid-cols-3">
                <div class="form-control">
                  <label class="label pb-1" for="resource-cpu-cores">
                    <span class="label-text">CPU cores</span>
                  </label>
                  <input
                    id="resource-cpu-cores"
                    name="resources[cpu_cores]"
                    type="number"
                    step="0.05"
                    value={@resources["cpu_cores"]}
                    class="input input-bordered input-sm w-full"
                    data-testid="resource-cpu"
                  />
                </div>
                <div class="form-control">
                  <label class="label pb-1" for="resource-memory-mb">
                    <span class="label-text">Memory (MB)</span>
                  </label>
                  <input
                    id="resource-memory-mb"
                    name="resources[memory_mb]"
                    type="number"
                    step="1"
                    min="1"
                    value={@resources["memory_mb"]}
                    class="input input-bordered input-sm w-full"
                    data-testid="resource-memory"
                  />
                </div>
                <div class="form-control">
                  <label class="label pb-1" for="resource-storage-gb">
                    <span class="label-text">Storage (GB)</span>
                  </label>
                  <input
                    id="resource-storage-gb"
                    name="resources[storage_gb]"
                    type="number"
                    step="1"
                    min="0"
                    value={@resources["storage_gb"]}
                    class="input input-bordered input-sm w-full"
                    data-testid="resource-storage"
                  />
                </div>
              </div>

              <div
                :if={@below_recommendation?}
                id="below-recommendation-warning"
                class="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
                data-testid="below-recommendation-warning"
                role="alert"
              >
                <p class="font-medium">
                  This is below what {@app.name} recommends — it may run slowly or fail.
                </p>
                <label class="label cursor-pointer justify-start gap-3 pt-2">
                  <input
                    type="checkbox"
                    name="resources[below_ack]"
                    id="below-recommendation-ack"
                    checked={@below_ack}
                    class="checkbox checkbox-warning checkbox-sm"
                    data-testid="below-recommendation-ack"
                  />
                  <span class="label-text">
                    I understand — deploy with less than the recommended resources
                  </span>
                </label>
              </div>

              <div
                class="flex items-center justify-between gap-4 rounded-lg bg-base-300/50 px-4 py-3 text-sm"
                data-testid="resources-price"
              >
                <span>
                  {@app.name} <span class="font-mono">v{@selected.version}</span>
                  <span :if={@resources} class="opacity-60">
                    · {allocation_text(@resources)}
                  </span>
                </span>
                <.price_line selected={@selected} resources={@resources} />
              </div>

              <div class="card-actions justify-end pt-2">
                <button type="button" phx-click="back-env" class="btn btn-ghost btn-sm">
                  Back
                </button>
                <button
                  type="submit"
                  class="btn btn-primary btn-sm"
                  disabled={@below_recommendation? and not @below_ack}
                  data-testid="continue-resources"
                >
                  Continue
                </button>
              </div>
            </form>
          </div>
        </div>

        <div :if={@step == 4} class="card bg-base-200">
          <div class="card-body gap-4">
            <h2 class="card-title text-base">Name your instance</h2>
            <div
              :if={@selected}
              class="flex items-center justify-between rounded-lg bg-base-300/50 px-4 py-3 text-sm"
              data-testid="price-summary"
            >
              <span>
                {@app.name} <span class="font-mono">v{@selected.version}</span>
                <span :if={@resources} class="opacity-60">
                  · {allocation_text(@resources)}
                </span>
              </span>
              <.price_line selected={@selected} resources={@resources} />
            </div>
            <ul
              :if={step_invisible_errors(@form) != []}
              id="deploy-errors"
              class="text-sm text-error space-y-1"
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
              <p class="text-xs opacity-60">
                We'll generate the subdomain — you can rename nothing else later (M3).
              </p>
              <div class="card-actions justify-end pt-2">
                <button type="button" phx-click="back-resources" class="btn btn-ghost btn-sm">
                  Back
                </button>
                <button
                  type="submit"
                  class="btn btn-primary"
                  phx-disable-with="Deploying…"
                  data-testid="deploy-submit"
                >
                  Deploy {@app.name}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The price line is one component so the resources step and the name
  # step can't disagree. Interim (#180): only the recommended allocation
  # carries a live estimate — custom allocations bill at the recommended
  # size until the allocation-following pricing semantics are decided
  # (open-questions.md); the shown figure is what the ledger charges.
  defp price_line(%{selected: selected, resources: resources} = assigns) do
    assigns =
      assign(assigns,
        size: selected.recommended_size,
        at_recommendation: recommendation?(selected, resources)
      )

    ~H"""
    <span :if={@size && @at_recommendation} class="font-semibold">
      {FluxVale.Pricing.format_usd(@size.monthly_cents)}/mo
    </span>
    <span :if={@size && not @at_recommendation} class="text-right opacity-70">
      billed at the recommended size — {FluxVale.Pricing.format_usd(@size.monthly_cents)}/mo
      <span class="block text-xs">
        custom-allocation pricing is being finalized
      </span>
    </span>
    """
  end

  # The env surface is a map attribute, not a nested form: plain fields
  # under env_values[NAME] arrive as a map on submit. Values are strings
  # end to end (the K8s Secret's exact contents).
  defp env_input(%{spec: %{type: :boolean}} = assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      class="select select-bordered select-sm w-full max-w-xs font-normal"
    >
      {Phoenix.HTML.Form.options_for_select(
        [{"true", "true"}, {"false", "false"}],
        value(@spec, @value)
      )}
    </select>
    """
  end

  defp env_input(%{spec: %{type: :integer}} = assigns) do
    ~H"""
    <input
      id={@id}
      name={@name}
      type="number"
      step="1"
      value={value(@spec, @value)}
      class="input input-bordered input-sm w-full max-w-xs"
    />
    """
  end

  defp env_input(assigns) do
    ~H"""
    <input
      id={@id}
      name={@name}
      type={input_type(@spec)}
      value={value(@spec, @value)}
      class="input input-bordered input-sm w-full max-w-xs"
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

  # Live: every keystroke re-renders the below-recommendation warning
  # and keeps the ack coherent (an edit that leaves the recommendation
  # band drops a stale ack). Floor errors don't fire here — a number
  # mid-typing ("0" of "0.5") must not flash errors; they gate at
  # continue, and again at the form cast on save.
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
    # there is nothing to render (to-env's guard posture).
    if socket.assigns.selected do
      {:noreply, assign(socket, step: 3)}
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
  # Input state is strings end to end (the number inputs' exact
  # contents); parsing happens at the edges — here for warnings, at
  # resources-continue for floor errors, at the form cast for the
  # authoritative say.

  defp initial_resources(version) do
    %{
      "cpu_cores" => Decimal.to_string(version.default_cpu_cores),
      "memory_mb" => Integer.to_string(version.default_memory_mb),
      "storage_gb" => Integer.to_string(version.default_storage_gb)
    }
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
  # memory ≥ 1 MB, storage ≥ 0 GB — legal-allocation bounds mirroring
  # Size's own, not UX. They block regardless of acknowledgment. The
  # maxima mirror the resource-side ceilings: instant field errors
  # here, not an encode crash at save.
  defp allocation_errors(resources) do
    case parse_allocation(resources) do
      {:ok, allocation} ->
        checks = [
          {Decimal.compare(allocation.cpu_cores, 0) != :gt, "CPU cores must be greater than 0"},
          {allocation.memory_mb < 1, "Memory must be at least 1 MB"},
          {allocation.memory_mb > 65_536, "Memory must be at most 65536 MB"},
          {allocation.storage_gb < 0, "Storage cannot be negative"},
          {allocation.storage_gb > 10_240, "Storage must be at most 10240 GB"}
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
         {:ok, memory} <- parse_integer(resources["memory_mb"]),
         {:ok, storage} <- parse_integer(resources["storage_gb"]) do
      {:ok, %{cpu_cores: cpu, memory_mb: memory, storage_gb: storage}}
    end
  end

  defp parse_decimal(raw) do
    case Decimal.parse(raw) do
      {value, ""} ->
        # Ash's own cast rejects non-finite decimals — the preview must
        # not be looser than the authoritative say (NaN would crash
        # every compare; Infinity would walk straight past the floors).
        if Decimal.nan?(value) or Decimal.inf?(value) do
          {:error, ["CPU cores must be a number"]}
        else
          {:ok, value}
        end

      _other ->
        {:error, ["CPU cores must be a number"]}
    end
  end

  defp parse_integer(raw) do
    case Integer.parse(raw) do
      {value, ""} -> {:ok, value}
      _other -> {:error, ["Memory and storage must be whole numbers"]}
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
  # version defaults.
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
