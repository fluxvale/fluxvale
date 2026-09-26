defmodule FluxValeWeb.CatalogLive.Deploy do
  @moduledoc """
  The deploy stepper (#74): pick AppVersion → env vars (schema-rendered,
  #70) → name → Instance. One `AshPhoenix.Form.for_create/4` carries the
  whole flow (ADR-0002: forms straight onto resources); steps are UI
  state, not separate forms.

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
        app = Ash.load!(app, :app_versions, actor: user)
        versions = Enum.sort_by(app.app_versions, & &1.version, :desc)

        socket =
          socket
          |> assign(app: app, versions: versions)
          |> assign(step: 1, version_id: nil, env_values: %{}, schema: %{})
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
          <li class={["step", @step >= 3 && "step-primary"]}>Name</li>
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
            <h2 class="card-title text-base">Name your instance</h2>
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
                <button type="button" phx-click="back-env" class="btn btn-ghost btn-sm">
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
          |> assign(step: 2, schema: sorted_schema(version))
          |> validate_step(%{"app_version_id" => version.id})

        {:noreply, socket}
    end
  end

  def handle_event("back-version", _params, socket) do
    {:noreply, assign(socket, step: 1)}
  end

  def handle_event("env-continue", params, socket) do
    env_values = drop_empty(params["env_values"] || %{})

    socket =
      socket
      |> assign(env_values: env_values, step: 3)
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

  def handle_event("back-env", _params, socket) do
    {:noreply, assign(socket, :step, 2)}
  end

  def handle_event("save", %{"instance" => instance_params}, socket) do
    params =
      socket.assigns.form.params
      |> Map.merge(instance_params)
      |> Map.put("env_vars", socket.assigns.env_values)

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
end
