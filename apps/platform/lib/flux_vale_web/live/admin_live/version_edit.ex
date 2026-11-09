defmodule FluxValeWeb.AdminLive.VersionEdit do
  @moduledoc """
  The admin version edit form (#501): the surgery surface over
  `AppVersion`'s own `:update` action.

  The page's job is the coherence contract, stated up front: the
  blueprint's compute defaults (what provisioning grants) and the
  recommended compute class (what billing prices) must describe the
  same CPU + memory shape — storage is the version's own honest
  default, priced per GB on its axis (#558). While the admin edits,
  the page compares the defaults against the selected size and names
  the mismatched dimensions before any submit, quoting the size's
  compute. The comparison is display data — the action's
  `ValidateSizeMatchesAllocation` stays the enforcement, and a save
  with a mismatch fails there with its honest error.

  First-run contract edits ride the page too: the pattern, guaranteed
  env, forbidden keys, and guidance land in the same save, and the
  `ValidateFirstRunEnv` key-ownership rule fails loudly on overlap,
  naming where the colliding fields are edited today (the debug admin).
  The pattern select derives from the contract type's own pattern list,
  so a new pattern can never fall outside the select and be silently
  deleted by a default. An untouched contract block is never rebuilt:
  the KEY=VALUE round-trip is lossy, so the stored struct rides the
  save unchanged unless the operator actually edited the text.
  Every write runs through the action with the platform-admin actor and
  `authorize?: true` — the domain policies decide, never the UI.
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Types.FirstRunContract
  alias FluxVale.Pricing.Size
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    # The chrome assigns (current_user, username, nav_section) ride the
    # AdminChrome on_mount on the :admin live_session — this mount adds
    # only the page's own data.
    admin = socket.assigns.current_user

    with {:ok, version} <- Ash.get(AppVersion, id, actor: admin, authorize?: true),
         {:ok, version} <- Ash.load(version, [:app, :recommended_size], actor: admin) do
      form = build_form(version, admin)

      {:ok,
       socket
       |> assign(version: version, sizes: sizes(admin), pattern_options: pattern_options())
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

  # Derived from the type's own pattern list: a third pattern added to
  # the type appears here automatically, and can never be silently
  # replaced by a select default on save. A pattern unknown to the type
  # needs no guard of its own: the type's cast rejects it on every
  # write path (actions and Ash.Seed alike), so such a row cannot exist
  # to be rendered.
  defp pattern_options do
    [{gettext("No contract"), ""}] ++
      Enum.map(FirstRunContract.known_patterns(), fn pattern ->
        {pattern_label(pattern), Atom.to_string(pattern)}
      end)
  end

  defp pattern_label(:first_registered_user_admin),
    do: gettext("First registered user is the admin")

  defp pattern_label(:first_open_sets_password),
    do: gettext("First open sets the server password")

  defp pattern_label(:default_admin_credentials),
    do: gettext("Sign in with the shipped default admin, then change the password")

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
    form =
      AshPhoenix.Form.validate(socket.assigns.form, merged_params(params, socket.assigns.version))

    {:noreply, assign_edit_state(socket, form)}
  end

  def handle_event("save", params, socket) do
    av_params = merged_params(params, socket.assigns.version)
    form = AshPhoenix.Form.validate(socket.assigns.form, av_params)

    case AshPhoenix.Form.submit(form, params: av_params) do
      {:ok, saved} ->
        admin = socket.assigns.current_user
        version = Ash.load!(saved, [:app, :recommended_size], actor: admin)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Version saved."))
         |> assign(version: version, sizes: sizes(admin))
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
  defp merged_params(params, version) do
    av = params["app_version"] || %{}

    case contract_params(params, version) do
      :unchanged -> av
      {:contract, contract} -> Map.put(av, "first_run", contract)
    end
  end

  defp contract_params(%{"first_run_pattern" => pattern} = params, version) do
    loaded = version.first_run

    cond do
      # "No contract" on a version without one: nothing to say.
      pattern == "" and is_nil(loaded) ->
        :unchanged

      # "No contract" on a contracted version: an explicit removal.
      pattern == "" ->
        {:contract, nil}

      # The form shows exactly what is stored: the operator touched
      # nothing in the block, so the stored struct rides the save
      # untouched (an absent param means keep). The KEY=VALUE
      # round-trip is lossy (embedded newlines, trailing whitespace),
      # and rebuilding would silently rewrite data nobody edited.
      not is_nil(loaded) and pattern == Atom.to_string(loaded.pattern) and
          untouched_texts?(params, loaded) ->
        :unchanged

      true ->
        {:contract, rebuilt(params, loaded, pattern)}
    end
  end

  defp contract_params(_params, _version), do: :unchanged

  defp untouched_texts?(params, loaded) do
    (params["first_run_env"] || "") == env_lines(loaded.env) and
      (params["first_run_forbidden"] || "") == Enum.join(loaded.forbidden_env, "\n") and
      (params["first_run_guidance"] || "") == loaded.guidance
  end

  # Per-field carry: a textarea that still shows what the page loaded
  # contributes the stored value, not a re-parse of its own rendering.
  defp rebuilt(params, loaded, pattern) do
    %{
      "pattern" => pattern,
      "env" =>
        carried(
          params["first_run_env"],
          loaded,
          fn c -> env_lines(c.env) end,
          fn c -> c.env end,
          &parse_env/1
        ),
      "forbidden_env" =>
        carried(
          params["first_run_forbidden"],
          loaded,
          fn c -> Enum.join(c.forbidden_env, "\n") end,
          fn c -> c.forbidden_env end,
          &parse_lines/1
        ),
      "guidance" => carried_text(params["first_run_guidance"], loaded)
    }
  end

  defp carried(param, loaded, render, read, parse) do
    cond do
      is_nil(loaded) -> parse.(param || "")
      param == render.(loaded) -> read.(loaded)
      true -> parse.(param || "")
    end
  end

  defp carried_text(param, loaded) do
    cond do
      is_nil(loaded) -> param || ""
      param == loaded.guidance -> loaded.guidance
      true -> param || ""
    end
  end

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

  # The page's display-side coherence read: the compute defaults as
  # they stand in the form against the selected size's compute, per
  # dimension. nil whenever anything is unparseable — the field errors
  # carry that story.
  defp mismatch(assigns, form) do
    size = selected_size(assigns, form)
    values = default_values(assigns.version, form)

    if size && values do
      dims = mismatched_dims(size, values)
      if dims == [], do: nil, else: %{size: size, dims: dims}
    else
      nil
    end
  end

  defp mismatched_dims(size, values) do
    Enum.filter(
      [:cpu, :memory],
      fn
        :cpu -> not Decimal.eq?(size.cpu_cores, values.cpu)
        :memory -> size.memory_mb != values.memory_mb
      end
    )
  end

  defp dim_names(dims) do
    Enum.map_join(dims, ", ", &dim_name/1)
  end

  defp dim_name(:cpu), do: gettext("CPU cores")
  defp dim_name(:memory), do: gettext("memory")

  defp default_values(version, form) do
    cpu_text =
      form_value(form, "default_cpu_cores", Decimal.to_string(version.default_cpu_cores))

    memory_text =
      form_value(form, "default_memory_mb", Integer.to_string(version.default_memory_mb))

    with {cpu, ""} <- Decimal.parse(cpu_text),
         {memory_mb, ""} <- Integer.parse(memory_text) do
      %{cpu: cpu, memory_mb: memory_mb}
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
      wide
    >
      <%!-- The console lane (#593): `wide` chrome + `appgram console`
      — flush sidebar, the page fills the space beside it. The form
      cards keep the settings idiom's max-w-2xl measure: a textarea at
      viewport width is unreadable, and this page is mostly textareas.
      --%>
      <div class="appgram console contents" data-testid="admin-version-edit">
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

        <%!-- The section sidebar (Am. 4, the #568 idiom); the version
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
              <.form
                for={@form}
                id="version-edit-form"
                phx-change="validate"
                phx-submit="save"
                class="space-y-6"
              >
                <%!-- Blueprint and size, presented together. The static
            rule is a quiet note; the live mismatch is the loudest thing
            on the page, naming the dimensions that drifted. --%>
                <.card class="max-w-2xl space-y-5" data-testid="admin-version-allocation">
                  <div>
                    <h2 class="text-base font-medium text-ink">{gettext("Blueprint and size")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      {gettext("What provisioning grants and what billing prices, in one place.")}
                    </p>
                  </div>

                  <.callout tone="info" data-testid="admin-version-coherence-rule">
                    <p>
                      {gettext(
                        "The blueprint's compute defaults and the size must match. Every save checks them against each other."
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
                    data-testid="admin-version-coherence-mismatch"
                  >
                    <p>
                      {ngettext(
                        "%{dims} does not match the size. The size %{slug} provides %{compute}.",
                        "%{dims} do not match the size. The size %{slug} provides %{compute}.",
                        length(@mismatch.dims),
                        dims: dim_names(@mismatch.dims),
                        slug: @mismatch.size.slug,
                        compute: AdminComponents.compute_text(@mismatch.size)
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
            rule rides the same save, and the failure names where the
            colliding fields live. --%>
                <.card class="max-w-2xl space-y-5" data-testid="admin-version-firstrun">
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
                    <p>
                      {gettext(
                        "A collision is with the blueprint env fields: default_env_vars, configurable_env_vars, or the instance URL env. Those fields are edited in the debug admin at /admin/ash."
                      )}
                    </p>
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

                  <%!-- The deploy's own env var, read-only here: contract keys
              must stay out of it too, and the admin should see it while
              editing the contract. --%>
                  <div :if={@version.instance_url_env} data-testid="admin-version-instance-url-env">
                    <p class="mb-1.5 text-sm font-medium text-ink-muted">
                      {gettext("Instance URL env")}
                    </p>
                    <div class="rounded-control border border-line bg-panel-raised px-3 py-2 font-mono text-sm text-ink">
                      {@version.instance_url_env}
                    </div>
                  </div>
                </.card>

                <.button type="submit" data-testid="admin-version-save">
                  {gettext("Save version")}
                </.button>
              </.form>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The select's options read as compute facts: slug, then the class.
  # The admin picks with the rule already visible.
  defp size_options(sizes) do
    Enum.map(sizes, fn size ->
      {"#{size.slug}: #{AdminComponents.compute_text(size)}", size.id}
    end)
  end
end
