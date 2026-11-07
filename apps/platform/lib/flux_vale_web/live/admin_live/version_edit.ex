defmodule FluxValeWeb.AdminLive.VersionEdit do
  @moduledoc """
  The admin version edit form (#501): the surgery surface over
  `AppVersion`'s own `:update` action.

  The page's job is the coherence contract, stated up front: the
  blueprint defaults (what provisioning grants) and the recommended
  size's envelope (what billing prices) must describe the same
  allocation. While the admin edits, the page compares the defaults
  against the selected size and says a mismatch will not pass, before
  any submit. The comparison is display data — the action's
  `ValidateSizeMatchesAllocation` stays the enforcement, and a save
  with a mismatch fails there with its honest error.

  First-run contract edits ride the page too: the pattern, guaranteed
  env, forbidden keys, and guidance land in the same save, and the
  `ValidateFirstRunEnv` key-ownership rule fails loudly on overlap.
  Every write runs through the action with the platform-admin actor and
  `authorize?: true` — the domain policies decide, never the UI.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Pricing.Size
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.UserAuth

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, session, socket) do
    admin = UserAuth.resolve_user(session)

    with {:ok, version} <- Ash.get(AppVersion, id, actor: admin, authorize?: true),
         {:ok, version} <- Ash.load(version, [:app, :recommended_size], actor: admin) do
      form = build_form(version, admin)

      {:ok,
       socket
       |> assign(
         current_user: admin,
         actor_orgs: [],
         personal_org_id: nil,
         username: admin && admin.username,
         nav_section: nil,
         version: version,
         sizes: sizes(admin),
         pattern_options: pattern_options()
       )
       |> assign(contract_text(version))
       |> assign_edit_state(form)}
    else
      _not_found_or_denied ->
        # Unknown id and policy denial read the same: this version is
        # not editable from here (the org-settings posture).
        {:ok,
         socket
         |> put_flash(:error, gettext("That version is not editable here."))
         |> push_navigate(to: ~p"/admin/catalog")}
    end
  end

  defp sizes(admin) do
    Size
    |> Ash.Query.for_read(:read, %{}, actor: admin)
    |> Ash.Query.sort(monthly_cents: :asc)
    |> Ash.read!()
  end

  defp pattern_options do
    [
      {gettext("No contract"), ""},
      {gettext("First registered user is the admin"), "first_registered_user_admin"},
      {gettext("First open sets the server password"), "first_open_sets_password"}
    ]
  end

  defp build_form(version, admin) do
    version
    |> AshPhoenix.Form.for_update(:update, as: "app_version", actor: admin, authorize?: true)
    |> to_form()
  end

  # The first-run contract as textarea-friendly text: the pattern atom,
  # one KEY=VALUE line per guaranteed env var, one key per line for the
  # forbidden list. Sorted so the render is stable.
  defp contract_text(version) do
    case version.first_run do
      nil ->
        [
          first_run_pattern: "",
          first_run_env: "",
          first_run_forbidden: "",
          first_run_guidance: ""
        ]

      contract ->
        [
          first_run_pattern: Atom.to_string(contract.pattern),
          first_run_env: env_lines(contract.env),
          first_run_forbidden: Enum.join(contract.forbidden_env, "\n"),
          first_run_guidance: contract.guidance
        ]
    end
  end

  defp env_lines(env) do
    env
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.sort()
    |> Enum.join("\n")
  end

  @impl Phoenix.LiveView
  def handle_event("validate", params, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, merged_params(params))

    {:noreply, assign_edit_state(socket, form)}
  end

  def handle_event("save", params, socket) do
    av_params = merged_params(params)
    form = AshPhoenix.Form.validate(socket.assigns.form, av_params)

    case AshPhoenix.Form.submit(form, params: av_params) do
      {:ok, saved} ->
        admin = socket.assigns.current_user
        version = Ash.load!(saved, [:app, :recommended_size], actor: admin)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Version saved."))
         |> assign(version: version)
         |> assign(contract_text(version))
         |> assign(form: build_form(version, admin))
         |> assign(mismatch: nil, repointed: nil, first_run_errors: [])}

      {:error, error_form} ->
        # The action speaking (coherence, key ownership, or a cast):
        # the honest errors render on their fields.
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save the version. Check the errors below."))
         |> assign_edit_state(to_form(error_form))}
    end
  end

  # The first-run contract rides the change payload as top-level keys
  # (pattern, env text, forbidden keys, guidance) — this builds them
  # into the one `first_run` param the action accepts. Absent keys
  # carry no opinion, so a crafted partial event cannot silently strip
  # a contract.
  defp merged_params(params) do
    av = params["app_version"] || %{}

    case contract_params(params) do
      :unchanged -> av
      {:contract, contract} -> Map.put(av, "first_run", contract)
    end
  end

  defp contract_params(%{"first_run_pattern" => ""}), do: {:contract, nil}

  defp contract_params(%{"first_run_pattern" => pattern} = params) when is_binary(pattern) do
    {:contract,
     %{
       "pattern" => pattern,
       "env" => parse_env(params["first_run_env"] || ""),
       "forbidden_env" => parse_lines(params["first_run_forbidden"] || ""),
       "guidance" => params["first_run_guidance"] || ""
     }}
  end

  defp contract_params(_params), do: :unchanged

  defp parse_env(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  defp parse_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # The page's display-side coherence read: the defaults as they stand
  # in the form against the selected size's allocation. nil whenever
  # anything is unparseable — the field errors carry that story.
  defp mismatch(assigns, form) do
    size = selected_size(assigns, form)
    values = default_values(assigns.version, form)

    if size && values do
      matches? =
        Decimal.eq?(size.cpu_cores, values.cpu) and
          size.memory_mb == values.memory_mb and
          size.storage_gb == values.storage_gb

      if matches?, do: nil, else: size
    else
      nil
    end
  end

  defp default_values(version, form) do
    cpu_text =
      form_value(form, "default_cpu_cores", Decimal.to_string(version.default_cpu_cores))

    memory_text =
      form_value(form, "default_memory_mb", Integer.to_string(version.default_memory_mb))

    storage_text =
      form_value(form, "default_storage_gb", Integer.to_string(version.default_storage_gb))

    with {cpu, ""} <- Decimal.parse(cpu_text),
         {memory_mb, ""} <- Integer.parse(memory_text),
         {storage_gb, ""} <- Integer.parse(storage_text) do
      %{cpu: cpu, memory_mb: memory_mb, storage_gb: storage_gb}
    else
      _unparseable -> nil
    end
  end

  # Params are what the admin is looking at; the record is what a fresh
  # form shows. Blank inputs stay blank (the field error tells it).
  defp form_value(form, key, fallback) do
    case form.params[key] do
      nil -> fallback
      value -> value
    end
  end

  # cpu_cores is a Decimal on the record and a string in the params;
  # the input needs text (Decimal has no HTML-safe encoding).
  defp cpu_value(assigns) do
    form_value(
      assigns.form,
      "default_cpu_cores",
      Decimal.to_string(assigns.version.default_cpu_cores)
    )
  end

  defp selected_size(assigns, form) do
    case form.params["recommended_size_id"] do
      nil -> assigns.version.recommended_size
      id -> Enum.find(assigns.sizes, &(&1.id == id))
    end
  end

  # The version moving to a different size — the sanctioned first half
  # of "re-point, then move the size". Consequence copy rides it.
  defp repointed_size(assigns, form) do
    current = assigns.version.recommended_size
    selected = selected_size(assigns, form)

    if current && selected && selected.id != current.id, do: selected, else: nil
  end

  defp first_run_errors(form) do
    form
    |> AshPhoenix.Form.errors(format: :simple)
    |> Enum.filter(&(elem(&1, 0) == :first_run))
    |> Enum.map(&elem(&1, 1))
  end

  # The display layer over the form: the pre-submit coherence read, the
  # re-point read, and the first-run errors the action's validations
  # surfaced.
  defp assign_edit_state(socket, form) do
    assign(socket,
      form: form,
      mismatch: mismatch(socket.assigns, form),
      repointed: repointed_size(socket.assigns, form),
      first_run_errors: first_run_errors(form)
    )
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
      <div class="appgram contents" data-testid="admin-version-edit">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">
                {gettext("Edit version")}
                <span class="ml-2 font-mono text-2xl text-ink-muted">{@version.version}</span>
              </h1>
              <p class="mt-2 text-sm text-ink-muted">{@version.app.name}</p>
              <div class="mt-4">
                <.link
                  navigate={~p"/admin/catalog"}
                  data-testid="admin-catalog-back-link"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {gettext("Back to the catalog")}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <.form
            for={@form}
            id="version-edit-form"
            phx-change="validate"
            phx-submit="save"
            class="rise space-y-6 max-w-3xl"
          >
            <%!-- Blueprint and envelope, presented together, the rule
            stated before any editing starts. --%>
            <.card class="space-y-5" data-testid="admin-version-allocation">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("Blueprint and size")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext("What provisioning grants and what billing prices, in one place.")}
                </p>
              </div>

              <.callout
                tone="info"
                title={gettext("The coherence rule")}
                data-testid="admin-version-coherence-rule"
              >
                <p>
                  {gettext(
                    "The blueprint defaults and the size envelope must describe the same allocation. Every save checks them against each other."
                  )}
                </p>
              </.callout>

              <.input
                field={@form[:recommended_size_id]}
                type="select"
                label={gettext("Recommended size")}
                options={size_options(@sizes)}
                data-testid="admin-version-size-select"
              />

              <.callout
                :if={@mismatch}
                tone="warning"
                title={gettext("This save will not pass")}
                data-testid="admin-version-coherence-mismatch"
              >
                <p>
                  {gettext(
                    "The size %{slug} provides %{allocation}. The defaults must match it exactly.",
                    slug: @mismatch.slug,
                    allocation: AdminComponents.allocation_text(@mismatch)
                  )}
                </p>
              </.callout>

              <.callout
                :if={@repointed}
                tone="warning"
                title={gettext("Re-point ahead")}
                data-testid="admin-version-repoint"
              >
                <p>
                  {gettext(
                    "This version will point at %{slug}. Future deploys provision and bill %{slug} at %{rate}.",
                    slug: @repointed.slug,
                    rate: FluxVale.Pricing.format_monthly_rate(@repointed.monthly_cents)
                  )}
                </p>
              </.callout>

              <div class="grid gap-4 sm:grid-cols-3">
                <.input
                  field={@form[:default_cpu_cores]}
                  value={cpu_value(assigns)}
                  label={gettext("Default CPU cores")}
                  data-testid="admin-version-cpu"
                />
                <.input
                  field={@form[:default_memory_mb]}
                  type="number"
                  min="1"
                  label={gettext("Default memory (MB)")}
                  data-testid="admin-version-memory"
                />
                <.input
                  field={@form[:default_storage_gb]}
                  type="number"
                  min="0"
                  label={gettext("Default storage (GB)")}
                  data-testid="admin-version-storage"
                />
              </div>
            </.card>

            <%!-- The first-run contract, edited in place. The key-ownership
            rule rides the same save. --%>
            <.card class="space-y-5" data-testid="admin-version-firstrun">
              <div>
                <h2 class="text-base font-medium text-ink">{gettext("First-run contract")}</h2>
                <p class="mt-1 text-sm text-ink-muted">
                  {gettext("How the app becomes usable on first open.")}
                </p>
              </div>

              <.callout
                :if={@first_run_errors != []}
                tone="danger"
                title={gettext("The contract failed the save")}
                data-testid="admin-version-firstrun-errors"
              >
                <ul class="list-disc pl-4">
                  <li :for={message <- @first_run_errors}>{message}</li>
                </ul>
              </.callout>

              <.input
                type="select"
                name="first_run_pattern"
                label={gettext("Pattern")}
                options={@pattern_options}
                value={@first_run_pattern}
                data-testid="admin-version-firstrun-pattern"
              />
              <.input
                type="textarea"
                name="first_run_env"
                label={gettext("Guaranteed env, one KEY=VALUE per line")}
                value={@first_run_env}
                rows="3"
                data-testid="admin-version-firstrun-env"
              />
              <.input
                type="textarea"
                name="first_run_forbidden"
                label={gettext("Forbidden env keys, one per line")}
                value={@first_run_forbidden}
                rows="2"
                data-testid="admin-version-firstrun-forbidden"
              />
              <.input
                type="textarea"
                name="first_run_guidance"
                label={gettext("Owner guidance")}
                value={@first_run_guidance}
                rows="3"
                data-testid="admin-version-firstrun-guidance"
              />
            </.card>

            <.button type="submit" data-testid="admin-version-save">
              {gettext("Save version")}
            </.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The select's options read as allocation facts: slug, then the
  # envelope. The admin picks with the rule already visible.
  defp size_options(sizes) do
    Enum.map(sizes, fn size ->
      {"#{size.slug}: #{AdminComponents.allocation_text(size)}", size.id}
    end)
  end
end
