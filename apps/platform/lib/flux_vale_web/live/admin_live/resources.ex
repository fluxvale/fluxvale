defmodule FluxValeWeb.AdminLive.Resources do
  @moduledoc """
  The generic resource console (#595, slice 1: the read path, slice 2:
  the write path — both proven on Ops). Six mounts over the exposure
  registry (`FluxValeWeb.AdminConsole` — the security boundary): the
  domain picker, the domain page, the paginated index, the record show
  page, and the :new/:edit form mounts over `AshPhoenix.Form`.

  Every read and write runs with the operator as actor and repo-default
  authorization ON — the deliberate contrast with AshAdmin's effective
  `authorize?: false` (ADR-0027 Am. 1). No `authorize?: false`
  anywhere on this surface. Reads ride the primary read action with
  offset pagination (25 to a page, count-aware) and newest-first order
  where the resource carries `created_at`.

  Writes: `?action=` selects among the registry's allowed actions of
  the mount's type (default: the primary); a name the registry does
  not permit bounces honestly. Forms are generated per the action's
  accept list over public attributes (the plan's typed input mapping);
  per-field errors ride AshPhoenix's form data protocol into
  `<.input>`, and success navigates to the record's show page. Every
  button gates on `AdminConsole.visible?/3` — the bar shows nothing
  when nothing is permitted. Every write event re-resolves the actor
  from the session and requires the platform-admin role on the FRESH
  struct (the #571 demotion-window ruling) — the mount-resolved struct
  is never trusted for writes, and the submit carries the fresh actor
  so the policy reads the fresh role, not the stale one.

  Unknown domain/resource URL segments can never exist: they resolve
  against the registry's atoms and bounce to the landing with an honest
  flash (the size-edit idiom — the surface's existing unknown-page
  posture). An unknown record id is data, not a route — it flashes and
  bounces to the index the same way.

  Rendering is actor-safe by construction: the show page lists
  exactly the PUBLIC attributes in declaration order, and the index
  renders curated columns drawn only from public attributes plus the
  resource's DECLARED framework timestamps (created_at, pinned for
  row-age scanning) — audit metadata, never business attributes, the
  deliberate contrast with AshAdmin's render-everything posture
  (ADR-0027 Am. 1).
  """

  use FluxValeWeb, :live_view

  alias Ash.Resource.Info
  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Identity.User
  alias FluxValeWeb.AdminConsole
  alias FluxValeWeb.AdminResource
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.UserAuth

  @page_size 25

  # Auto columns: the label-ish attribute plus up to this many public
  # attrs, with created_at pinned last (the plan's columns contract).
  @auto_column_cap 4

  # The row-label heuristic's order (the plan): first match wins, else
  # the short id.
  @label_attr_order [:name, :title, :email, :key, :slug]

  @impl Phoenix.LiveView
  # The arms key on live_action, never params alone: LiveView merges
  # query params into mount params (the Topup :org posture), so
  # /admin/resources?domain=nope must stay the landing, not mount the
  # domain arm under a crafted query string.
  def mount(_params, _session, %{assigns: %{live_action: :domains}} = socket) do
    # D3's landing picker: the one Resources entry's target. Live
    # domains only; the honest one-liner names the pending set instead
    # of faking cards for it.
    domains =
      Enum.map(AdminConsole.domains(), fn domain ->
        %{key: domain.key, label: domain.label, count: length(domain.resources)}
      end)

    {:ok, assign(socket, domains: domains)}
  end

  def mount(%{"domain" => segment}, _session, %{assigns: %{live_action: :domain}} = socket) do
    case Enum.find(AdminConsole.domains(), &(Atom.to_string(&1.key) == segment)) do
      nil -> bounce_unknown(socket)
      domain -> {:ok, assign(socket, domain: domain_cards(domain))}
    end
  end

  def mount(
        %{"domain" => domain_segment, "resource" => resource_segment} = params,
        _session,
        %{assigns: %{live_action: :index}} = socket
      ) do
    case AdminConsole.fetch(domain_segment, resource_segment) do
      {:ok, entry} -> mount_index(entry, params, socket)
      :error -> bounce_unknown(socket)
    end
  end

  def mount(
        %{"domain" => domain_segment, "resource" => resource_segment, "id" => id},
        session,
        %{assigns: %{live_action: :show}} = socket
      ) do
    case AdminConsole.fetch(domain_segment, resource_segment) do
      {:ok, entry} -> mount_show(entry, id, session, socket)
      :error -> bounce_unknown(socket)
    end
  end

  def mount(
        %{"domain" => domain_segment, "resource" => resource_segment} = params,
        session,
        %{assigns: %{live_action: :new}} = socket
      ) do
    case AdminConsole.fetch(domain_segment, resource_segment) do
      {:ok, entry} -> mount_new(entry, params, session, socket)
      :error -> bounce_unknown(socket)
    end
  end

  def mount(
        %{"domain" => domain_segment, "resource" => resource_segment, "id" => id} = params,
        session,
        %{assigns: %{live_action: :edit}} = socket
      ) do
    case AdminConsole.fetch(domain_segment, resource_segment) do
      {:ok, entry} -> mount_edit(entry, id, params, session, socket)
      :error -> bounce_unknown(socket)
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
      <%!-- The console lane (#593 via #596): `wide` chrome + `appgram
      console` opts the page out of the centered measure — the sidebar
      anchors at the viewport gutter, the tables stretch. --%>
      <div class="appgram console contents" data-testid="admin-resources">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5" data-testid="admin-resources-title">
                {page_title(assigns)}
              </h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">{page_intro(assigns)}</p>
              <div :if={@live_action != :domains} class="mt-4">
                <.link
                  navigate={parent_path(assigns)}
                  data-testid="admin-resources-back"
                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                >
                  {parent_copy(assigns)}
                </.link>
              </div>
            </div>
          </div>
        </section>

        <%!-- The section sidebar (Am. 4, the #568 idiom); the console
        surfaces pass their nav state so the Resources group renders
        the active domain open and marks the active resource leaf (the
        landing passes none — every group renders collapsed). --%>
        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar
              current="resources"
              exact={@live_action == :domains}
              console={console_nav(assigns)}
              pending_requests={@pending_storage_requests}
            />

            <div class="min-w-0 flex-1 space-y-6">
              <%= case @live_action do %>
                <%!-- D3's domain picker: one card per live domain. --%>
                <% :domains -> %>
                  <div
                    class="grid items-start gap-4 sm:grid-cols-2"
                    data-testid="admin-resources-domains"
                  >
                    <.link
                      :for={domain <- @domains}
                      navigate={~p"/admin/resources/#{domain.key}"}
                      data-testid={"admin-resources-domain-#{domain.key}"}
                      class="block rounded-panel border border-line-strong bg-panel p-5 shadow-sm transition-colors hover:bg-panel-raised"
                    >
                      <p class="text-base font-medium text-ink">{domain.label}</p>
                      <p class="mt-1 text-sm text-ink-muted">
                        {ngettext("1 resource", "%{count} resources", domain.count)}
                      </p>
                    </.link>
                  </div>
                  <p class="text-sm text-ink-subtle" data-testid="admin-resources-pending">
                    {gettext(
                      "The sidebar groups every live domain here under Resources, collapsed to start. Not every domain is live yet. The ones here are fully supported."
                    )}
                  </p>
                <% :domain -> %>
                  <div
                    class="grid items-start gap-4 sm:grid-cols-2"
                    data-testid="admin-resources-domain"
                  >
                    <.link
                      :for={resource <- @domain.resources}
                      navigate={~p"/admin/resources/#{@domain.key}/#{resource.key}"}
                      data-testid={"admin-resources-resource-#{resource.key}"}
                      class="block rounded-panel border border-line-strong bg-panel p-5 shadow-sm transition-colors hover:bg-panel-raised"
                    >
                      <p class="text-base font-medium text-ink">{resource.label}</p>
                      <p :if={resource.note} class="mt-1 text-sm text-ink-muted">{resource.note}</p>
                    </.link>
                  </div>
                <% :index -> %>
                  <div class="space-y-4" data-testid="admin-resource-index">
                    <.callout :if={@note} tone="info" data-testid="admin-resource-note">
                      {@note}
                    </.callout>

                    <div class="flex flex-wrap items-center justify-between gap-3">
                      <div class="flex items-center gap-3">
                        <p class="text-sm text-ink-muted" data-testid="admin-resource-count">
                          {ngettext("1 row", "%{count} rows", @count)}
                        </p>
                        <AdminResource.new_button path={@new_path} />
                      </div>
                      <AdminResource.pagination
                        current={@page_number}
                        total={@total_pages}
                        path={@index_path}
                      />
                    </div>

                    <div :if={@rows_empty?} data-testid="admin-resource-empty">
                      <.empty_state title={gettext("No rows yet.")}>
                        {gettext("This table is empty. Rows appear here as they are created.")}
                      </.empty_state>
                    </div>

                    <div
                      :if={not @rows_empty?}
                      class="overflow-x-auto rounded-panel border border-line bg-panel text-ink"
                    >
                      <%!-- The console's table grammar (the .table
                      component's exact chrome, hand-rolled because the
                      generic engine needs per-shape cell control). The
                      floor is measured like the people surface's: the
                      widest registry row (the flags table — key 10rem,
                      enabled 5rem, rollout 6rem, description 13rem,
                      created 7rem, view 4rem ≈ 45rem tracks + padding)
                      needs 46rem before columns start crowding; below
                      it the table rides its own overflow-x-auto, never
                      the page. --%>
                      <table
                        class="w-full min-w-[46rem] text-sm"
                        data-testid="admin-resource-table"
                      >
                        <thead>
                          <tr class="border-b border-line text-left text-xs font-medium tracking-wide text-ink-muted uppercase">
                            <th
                              :for={col <- @columns}
                              class="px-4 py-3 font-medium"
                              data-testid={"admin-resource-col-#{col.name}"}
                            >
                              {col.label}
                            </th>
                            <th>
                              <span class="sr-only">{gettext("Actions")}</span>
                            </th>
                          </tr>
                        </thead>
                        <tbody id="admin-resource-rows" phx-update="stream">
                          <tr
                            :for={{dom_id, record} <- @streams.records}
                            id={dom_id}
                            class="border-b border-line last:border-0 transition-colors hover:bg-panel-raised/60"
                          >
                            <td
                              :for={col <- @columns}
                              class="px-4 py-3"
                              data-testid={"admin-resource-cell-#{col.name}-#{record.id}"}
                            >
                              <AdminResource.value
                                shape={col.shape}
                                value={Map.get(record, col.name)}
                              />
                            </td>
                            <td class="w-0 px-4 py-3 font-semibold">
                              <div class="flex gap-4">
                                <.link
                                  navigate={
                                    ~p"/admin/resources/#{@domain_key}/#{@resource_key}/#{record.id}"
                                  }
                                  data-testid={"admin-resource-view-#{record.id}"}
                                  class="text-sm font-medium text-link underline-offset-2 hover:underline"
                                >
                                  {gettext("View")}
                                </.link>
                              </div>
                            </td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </div>
                <% :show -> %>
                  <div
                    class="rounded-panel border border-line-strong bg-panel p-5 shadow-sm"
                    data-testid="admin-resource-show"
                  >
                    <dl class="divide-y divide-line">
                      <div
                        :for={field <- @fields}
                        class="grid gap-1 py-3 first:pt-0 sm:grid-cols-[10rem_1fr] sm:gap-4"
                        data-testid={"admin-resource-field-#{field.name}"}
                      >
                        <dt class="text-sm font-medium text-ink-muted">{field.label}</dt>
                        <dd class="min-w-0">
                          <AdminResource.value
                            shape={field.shape}
                            value={Map.get(@record, field.name)}
                            variant={:show}
                            id={"admin-resource-copy-#{field.name}"}
                          />
                        </dd>
                      </div>
                    </dl>

                    <div class="mt-4">
                      <AdminResource.actions_bar
                        update_actions={@update_actions}
                        destroy_actions={@destroy_actions}
                      />
                    </div>
                  </div>

                  <div :if={@confirm} class="rise">
                    <.confirm_block
                      title={gettext("Delete %{record}?", record: @confirm.label)}
                      body={
                        gettext(
                          "This permanently deletes the record and everything it owns. This cannot be undone."
                        )
                      }
                      action={gettext("Yes, delete this record")}
                      event="confirm-destroy"
                      action_testid="admin-resource-destroy-confirm"
                      cancel_testid="admin-resource-destroy-cancel"
                      myself={nil}
                    />
                  </div>
                <% :new -> %>
                  <div class="space-y-4" data-testid="admin-resource-form">
                    <.callout :if={@note} tone="info" data-testid="admin-resource-note">
                      {@note}
                    </.callout>

                    <div class="rounded-panel border border-line-strong bg-panel p-5 shadow-sm">
                      <.record_form
                        form={@form}
                        fields={@fields}
                        submit={gettext("Create %{name}", name: @resource_label)}
                      />
                    </div>
                  </div>
                <% :edit -> %>
                  <div
                    class="rounded-panel border border-line-strong bg-panel p-5 shadow-sm"
                    data-testid="admin-resource-form"
                  >
                    <.record_form form={@form} fields={@fields} submit={gettext("Save changes")} />
                  </div>
              <% end %>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # -- mounts -------------------------------------------------------------

  defp mount_index(entry, params, socket) do
    admin = socket.assigns.current_user
    page_number = parse_page(params["page"])
    page = read_page(entry.module, page_number, admin)
    count = page.count || 0
    total_pages = AdminResource.total_pages(count, @page_size)

    if page_number > total_pages and count > 0 do
      # A page past the end bounces to the real last page (the People
      # :home bounce idiom) — an honest URL, not a misleadingly empty
      # table.
      {:ok, push_navigate(socket, to: "#{index_path(entry)}?page=#{total_pages}")}
    else
      socket =
        socket
        |> assign(
          domain_key: entry.domain.key,
          domain_label: entry.domain.label,
          resource_key: entry.key,
          resource_label: resource_label(entry),
          note: entry.config[:note],
          columns: columns(entry),
          count: count,
          page_number: page_number,
          total_pages: total_pages,
          rows_empty?: page.results == [],
          index_path: index_path(entry),
          # The create affordance: only when the actor may run at
          # least one allowed create action (nil renders nothing).
          new_path: new_path(entry, admin)
        )
        |> stream(:records, page.results, reset: true)

      {:ok, socket}
    end
  end

  defp mount_show(entry, id, session, socket) do
    admin = socket.assigns.current_user

    case Ash.get(entry.module, id, actor: admin) do
      {:ok, record} ->
        {:ok,
         assign(socket,
           admin_session: session,
           resource_module: entry.module,
           domain_key: entry.domain.key,
           domain_label: entry.domain.label,
           resource_key: entry.key,
           resource_label: resource_label(entry),
           label_name: label_attr(entry),
           record: record,
           record_label: record_label(record, label_attr(entry)),
           fields: fields(entry.module),
           index_path: index_path(entry),
           update_actions: update_actions(entry, record.id, admin),
           destroy_actions: destroy_actions(entry, admin),
           confirm: nil
         )}

      {:error, _unknown_or_refused} ->
        # An unknown id and a policy denial read the same: this record
        # is not available from here (the size-edit posture).
        {:ok,
         socket
         |> put_flash(:error, gettext("That record is not available here."))
         |> push_navigate(to: index_path(entry))}
    end
  end

  defp mount_new(entry, params, session, socket) do
    admin = socket.assigns.current_user

    case form_action(entry, :create, params["action"]) do
      {:ok, action} ->
        {:ok,
         assign(socket,
           admin_session: session,
           domain_key: entry.domain.key,
           domain_label: entry.domain.label,
           resource_key: entry.key,
           resource_label: resource_label(entry),
           note: entry.config[:note],
           index_path: index_path(entry),
           form:
             entry.module
             |> AshPhoenix.Form.for_create(action.name, form_opts(admin))
             |> to_form(),
           fields: form_fields(entry.module, action)
         )}

      :error ->
        # A read-only resource has no :new, and a crafted ?action=
        # naming anything the registry does not permit here reads the
        # same: bounce to the index honestly.
        {:ok,
         socket
         |> put_flash(:error, gettext("That action is not available here."))
         |> push_navigate(to: index_path(entry))}
    end
  end

  defp mount_edit(entry, id, params, session, socket) do
    admin = socket.assigns.current_user

    with {:ok, record} <- Ash.get(entry.module, id, actor: admin),
         {:ok, action} <- form_action(entry, :update, params["action"]) do
      {:ok,
       assign(socket,
         admin_session: session,
         domain_key: entry.domain.key,
         domain_label: entry.domain.label,
         resource_key: entry.key,
         resource_label: resource_label(entry),
         index_path: index_path(entry),
         form:
           record
           |> AshPhoenix.Form.for_update(action.name, form_opts(admin))
           |> to_form(),
         fields: form_fields(entry.module, action)
       )}
    else
      {:error, _unknown_or_refused} ->
        # The record read refused or missed: the same bounce mount_show
        # answers (the size-edit posture).
        {:ok,
         socket
         |> put_flash(:error, gettext("That record is not available here."))
         |> push_navigate(to: index_path(entry))}

      :error ->
        # ?action= naming an update action the registry does not permit
        # here: bounce to the record's page — the record exists.
        {:ok,
         socket
         |> put_flash(:error, gettext("That action is not available here."))
         |> push_navigate(to: show_path(entry.domain.key, entry.key, id))}
    end
  end

  # -- events ---------------------------------------------------------------

  # The form's live validation: per-field errors ride AshPhoenix's form
  # data protocol into <.input> as the operator types.
  @impl Phoenix.LiveView
  def handle_event("validate", %{"record" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  # Every save re-resolves the actor first (the #571 demotion-window
  # gate) and the submit carries the FRESH actor, so the policy reads
  # the fresh role — the form's mount-time actor struct is never the
  # authorization answer.
  def handle_event("save", %{"record" => params}, socket) do
    case reauthorized_actor(socket) do
      {:ok, admin} -> attempt_save(socket, params, admin)
      :revoked -> {:noreply, refused(socket)}
    end
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # The delete lever's click. The reveal rides a fresh domain read (the
  # people surface's open-withdraw posture): a record that vanished
  # between the show render and the click never opens a confirm.
  def handle_event("open-destroy", %{"action" => name}, socket) do
    case find_destroy_action(socket.assigns.destroy_actions, name) do
      nil ->
        # A crafted action value: no button ever rendered it.
        {:noreply, socket}

      action ->
        admin = socket.assigns.current_user

        case Ash.get(socket.assigns.resource_module, socket.assigns.record.id, actor: admin) do
          {:ok, fresh} ->
            {:noreply,
             assign(socket,
               confirm: %{
                 action: action.name,
                 label: record_label(fresh, socket.assigns.label_name)
               }
             )}

          {:error, _vanished} ->
            {:noreply, bounce_record_gone(socket)}
        end
    end
  end

  def handle_event("open-destroy", _params, socket), do: {:noreply, socket}

  # The destructive click. The quiet expired arm is the double-click
  # guard: the confirm already closed (or never opened), so there is
  # nothing to say and nothing to run.
  def handle_event("confirm-destroy", _params, socket) do
    case socket.assigns.confirm do
      %{action: action_name} ->
        case reauthorized_actor(socket) do
          {:ok, admin} -> attempt_destroy(socket, action_name, admin)
          :revoked -> {:noreply, refused(socket, confirm: nil)}
        end

      _expired ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel-confirm", _params, socket) do
    {:noreply, assign(socket, confirm: nil)}
  end

  # -- reads ---------------------------------------------------------------

  defp read_page(module, page_number, actor) do
    offset = (page_number - 1) * @page_size

    module
    |> Ash.Query.for_read(primary_read(module), %{}, actor: actor)
    |> sort_newest_first(module)
    |> Ash.read!(page: [limit: @page_size, offset: offset, count: true])
  end

  defp primary_read(module) do
    Info.primary_action(module, :read).name
  end

  # -- writes ----------------------------------------------------------------

  # The save itself: validate, then submit with the FRESH actor riding
  # action_opts (the probe-verified shape — the form's stored mount-time
  # actor is replaced at the action call, so the policy reads the fresh
  # role). Field errors re-render inline; success navigates to the
  # record's show page.
  defp attempt_save(socket, params, admin) do
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    case AshPhoenix.Form.submit(form, params: params, action_opts: [actor: admin]) do
      {:ok, record} ->
        {:noreply,
         socket
         |> put_flash(:info, save_flash(socket.assigns.live_action))
         |> push_navigate(
           to: show_path(socket.assigns.domain_key, socket.assigns.resource_key, record.id)
         )}

      {:error, error_form} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Could not save. Check the errors below."))
         |> assign(form: to_form(error_form))}
    end
  end

  # The destroy dispatch: re-read the record through the domain first
  # (the wallet reversal's posture — @confirm is only set by a fresh
  # read, but the click can land after the row moved), then destroy
  # through the confirmed action.
  defp attempt_destroy(socket, action_name, admin) do
    case Ash.get(socket.assigns.resource_module, socket.assigns.record.id, actor: admin) do
      {:ok, fresh} ->
        result =
          fresh
          |> Ash.Changeset.for_destroy(action_name, %{}, actor: admin, authorize?: true)
          |> Ash.destroy()

        case result do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("The record was deleted."))
             |> push_navigate(to: socket.assigns.index_path)}

          # The policy admits this actor (re-resolved above) and Ops
          # destroys carry no further guard, so the residual error
          # class is DB-down — not simulatable under the sandbox.
          # coveralls-ignore-start
          {:error, _refused} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("The record could not be deleted. Try again."))
             |> assign(confirm: nil)}

            # coveralls-ignore-stop
        end

      {:error, _vanished} ->
        {:noreply, bounce_record_gone(socket)}
    end
  end

  # The demotion-window gate behind every write (the #571 ruling,
  # wallet-detail's shape): AdminChrome resolves the actor ONCE, at
  # mount, and a socket outlives a demotion — so the write handlers
  # re-resolve from the session (which also re-checks token revocation)
  # and require the platform-admin role on the FRESH struct. Reads keep
  # the mount-resolved actor: the route pipeline and the AdminGate
  # mount check own that window; the writes own this one.
  defp reauthorized_actor(socket) do
    case UserAuth.resolve_user(socket.assigns.admin_session) do
      %User{} = actor ->
        if ActorIsPlatformAdmin.platform_admin?(actor), do: {:ok, actor}, else: :revoked

      # The revoked-token arm: same refusal as the demoted actor. The
      # demoted-actor tests carry the gate's behavior; this arm needs
      # minting and revoking the live session's jti out-of-band, which
      # the suite has no helper for.
      # coveralls-ignore-start
      _not_signed_in ->
        :revoked

        # coveralls-ignore-stop
    end
  end

  # The refusal every write answers a demoted or revoked actor with:
  # honest copy naming what to do, never a crash.
  defp refused(socket, extra \\ []) do
    socket
    |> put_flash(:error, revoked_copy())
    |> assign(Keyword.put(extra, :confirm, nil))
  end

  defp revoked_copy do
    gettext("Your admin access ended. Sign out and sign back in.")
  end

  defp bounce_record_gone(socket) do
    socket
    |> put_flash(:error, gettext("That record is not available here."))
    |> push_navigate(to: socket.assigns.index_path)
  end

  defp find_destroy_action(actions, name) do
    Enum.find(actions, &(Atom.to_string(&1.name) == name))
  end

  # The form build opts shared by both write mounts. The actor here is
  # the mount-resolved admin for form setup only (defaults, validation)
  # — the submit replaces it with the fresh actor (see attempt_save).
  defp form_opts(admin) do
    [as: "record", actor: admin, authorize?: true]
  end

  # The show page's Edit items: the registry's allowed update actions
  # the actor may run (intent AND truth at render — the plan's two
  # gates), one link each. Every link carries its ?action= so two
  # update actions never read as the same button.
  defp update_actions(entry, record_id, admin) do
    entry.module
    |> AdminConsole.allowed_actions(:update, entry.config)
    |> Enum.filter(&AdminConsole.visible?(admin, entry.module, &1.name))
    |> Enum.map(fn action ->
      base = ~p"/admin/resources/#{entry.domain.key}/#{entry.key}/#{record_id}/edit"

      %{
        name: action.name,
        path: "#{base}?action=#{action.name}",
        label: action_label(gettext("Edit"), action)
      }
    end)
  end

  # The show page's Delete items: same two gates over the destroy
  # actions; the button carries the action name to the confirm.
  defp destroy_actions(entry, admin) do
    entry.module
    |> AdminConsole.allowed_actions(:destroy, entry.config)
    |> Enum.filter(&AdminConsole.visible?(admin, entry.module, &1.name))
    |> Enum.map(fn action ->
      %{name: action.name, label: action_label(gettext("Delete"), action)}
    end)
  end

  # A non-primary action names itself in its label (derived like column
  # labels — see AdminResource's copy line); the primary keeps the
  # plain verb.
  defp action_label(base, action) do
    if action.primary?, do: base, else: "#{base}: #{AdminResource.label(action.name)}"
  end

  # The index's create affordance: the :new route when the actor may
  # run at least one allowed create action, nil to render nothing.
  defp new_path(entry, admin) do
    createable =
      entry.module
      |> AdminConsole.allowed_actions(:create, entry.config)
      |> Enum.any?(&AdminConsole.visible?(admin, entry.module, &1.name))

    if createable, do: ~p"/admin/resources/#{entry.domain.key}/#{entry.key}/new", else: nil
  end

  # Newest first where the resource declares a created_at timestamp.
  # The guard keeps the engine total for a future resource without one.
  defp sort_newest_first(query, module) do
    if declared_timestamp(module, :created_at) do
      Ash.Query.sort(query, created_at: :desc)
    else
      # coveralls-ignore-start - every registry resource declares
      # created_at (the intake sanity passes verify it); no reachable
      # resource exercises this arm.
      query
      # coveralls-ignore-stop
    end
  end

  # -- introspection ---------------------------------------------------------

  # The ONLY non-public values this surface ever renders: the framework
  # timestamps, sourced exclusively from the resource's
  # create_timestamp/update_timestamp declarations (the plan's amended
  # parity criterion 2) — audit metadata, never business attributes.
  # Ash 3.37 has no Info.timestamps/1, so the source is Ash's own
  # discriminator for exactly those declarations (the same predicate
  # that wires Ecto autogenerate).
  defp declared_timestamps(module) do
    attrs = Info.attributes(module)
    Enum.filter(attrs, &Ash.Schema.timestamp_attribute?/1)
  end

  defp declared_timestamp(module, name) do
    declared = declared_timestamps(module)
    Enum.find(declared, &(&1.name == name))
  end

  # Everything a column may be built from: public attributes plus the
  # declared timestamps. Configured column names resolve against this
  # set and nothing else — an unknown name is skipped, never guessed.
  defp column_sources(module) do
    public = Info.public_attributes(module)
    stamps = declared_timestamps(module)
    public_pairs = Enum.map(public, &{&1.name, &1})
    timestamp_pairs = Enum.map(stamps, &{&1.name, &1})
    Map.new(public_pairs ++ timestamp_pairs)
  end

  # Index columns: the registry's curated list when set, else the auto
  # shape — the label-ish attribute first, then the next public attrs
  # up to the cap, created_at (the DECLARED timestamp) pinned last.
  # The pinned stamp is engine metadata the plan's columns contract
  # pins deliberately — row-age scanning on every table — while the
  # show page stays the public-attributes contract.
  @doc """
  The index's columns for a registry entry. Public seam: the intake
  tests drive configured-column resolution through it without a live
  registry entry carrying config.
  """
  @spec columns(map()) :: [map()]
  def columns(entry) do
    case entry.config[:columns] do
      nil -> auto_columns(entry)
      names -> configured_columns(entry, names)
    end
  end

  @doc """
  The names of the resource's declared framework timestamps — the only
  non-public values this surface ever renders (the plan's amended
  parity criterion 2). Public seam: the actor-safety tests assert the
  index's column ceiling against the same source the engine reads.
  """
  @spec declared_timestamp_names(module()) :: [String.t()]
  def declared_timestamp_names(module) do
    declared = declared_timestamps(module)
    Enum.map(declared, &Atom.to_string(&1.name))
  end

  # -- write-action resolution (the ?action= selector) ------------------------

  @doc """
  The action a write mount builds its form over: `?action=` picks among
  the registry's allowed actions of that type (the plan's selector
  machinery), defaulting to the primary. `:error` answers a name the
  registry does not permit here — a machinery action, a mismatched
  type, or a read-only resource's empty set — and the caller bounces
  honestly. Public seam: the selector tests drive fabricated entries
  without a live registry config.
  """
  @spec form_action(map(), :create | :update, String.t() | nil) :: {:ok, map()} | :error
  def form_action(entry, type, nil) do
    allowed = AdminConsole.allowed_actions(entry.module, type, entry.config)
    pick = Enum.find(allowed, & &1.primary?) || List.first(allowed)
    if pick, do: {:ok, pick}, else: :error
  end

  def form_action(entry, type, requested) when is_binary(requested) do
    allowed = AdminConsole.allowed_actions(entry.module, type, entry.config)

    # String compare against the allowed set's existing atoms — a URL
    # string is never made into an atom (the registry's own rule).
    case Enum.find(allowed, &(Atom.to_string(&1.name) == requested)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  @doc """
  The form's field list for one write action: its accept list resolved
  against PUBLIC attributes (the actor-safety ceiling) PLUS its typed
  arguments, each mapped to its `<.input>` type per the plan's
  contracts table. Arguments are how named actions take input when
  accept is empty (Billing's `grant_goodwill`: `wallet_id` and
  `amount_cents` arrive as arguments, `accept([])`) — they ride the
  same form data protocol, so the mapping is the same shape. An accept
  name that is not a public attribute, or a shape the engine cannot
  map yet (maps and composites — slice 4 owns the JSON-textarea
  decision), is SKIPPED, never guessed at. Attributes render first,
  arguments after (an argument is context the attrs do not carry).
  Public seam: the field-mapping tests drive fabricated accept lists
  without mounting.
  """
  @spec form_fields(module(), map()) :: [map()]
  def form_fields(module, action) do
    attrs = Info.public_attributes(module)
    by_name = Map.new(attrs, &{&1.name, &1})
    accept = action.accept || []
    attr_fields = Enum.flat_map(accept, fn name -> resolve_form_field(by_name, name) end)
    # Map.get over a bare field read: fabricated test actions carry
    # only what they assert, not the full action struct.
    arguments = Map.get(action, :arguments) || []
    # Attrs win a name collision: both would write record[name] and
    # the second render would silently shadow the first, so a colliding
    # argument drops instead of racing. Sensitive?/public? need no
    # equivalent today — no permitted action carries a sensitive
    # argument; the registry parity intake (a new action forces a
    # config decision) is the trigger that revisits this.
    attr_names = MapSet.new(attr_fields, & &1.name)

    argument_fields =
      arguments
      |> Enum.reject(&(&1.name in attr_names))
      |> Enum.flat_map(&mapped_field/1)

    attr_fields ++ argument_fields
  end

  defp resolve_form_field(by_name, name) do
    case Map.fetch(by_name, name) do
      {:ok, attr} -> mapped_field(attr)
      :error -> []
    end
  end

  defp mapped_field(attr) do
    case AdminResource.input_type(attr) do
      nil -> []
      type -> [field_entry(attr, type)]
    end
  end

  defp field_entry(attr, type) do
    options = if(type == "select", do: AdminResource.enum_options(attr), else: nil)

    %{
      name: attr.name,
      label: AdminResource.label(attr.name),
      type: type,
      options: options,
      step: AdminResource.input_step(attr),
      required: AdminResource.input_required?(attr, type)
    }
  end

  defp auto_columns(entry) do
    attrs = Info.public_attributes(entry.module)
    label_name = label_attr(entry)

    label = column(find_attribute(entry.module, label_name))

    rest =
      attrs
      |> Enum.reject(&(&1.name in [:id, label_name]))
      |> Enum.take(@auto_column_cap - 1)
      |> Enum.map(&column/1)

    pinned = created_at_column(entry)

    [label] ++ rest ++ pinned
  end

  # The curated list honors names only — slices 4-5 trim wide resources
  # this way. An inert name (a renamed attribute, a typo) falls back by
  # being skipped: the row renders without it, never crashes, never
  # renders a non-public attribute it cannot resolve.
  defp configured_columns(entry, names) do
    sources = column_sources(entry.module)
    resolver = fn name -> resolve_column(sources, name) end
    Enum.flat_map(names, resolver)
  end

  defp resolve_column(sources, name) do
    case Map.fetch(sources, name) do
      {:ok, attr} -> [column(attr)]
      :error -> []
    end
  end

  defp column(attr) do
    %{
      name: attr.name,
      label: AdminResource.label(attr.name),
      shape: AdminResource.shape(attr)
    }
  end

  defp created_at_column(entry) do
    stamp = declared_timestamp(entry.module, :created_at)

    if stamp do
      [column(stamp)]
    else
      # coveralls-ignore-start - same arm as sort_newest_first: no
      # reachable registry resource lacks a created_at declaration.
      []
      # coveralls-ignore-stop
    end
  end

  defp find_attribute(module, name) do
    attrs = Info.attributes(module)
    Enum.find(attrs, &(&1.name == name))
  end

  defp label_attr(entry) do
    override = entry.config[:label_attr]
    label_attr(entry, override)
  end

  # nil before the atom clause — nil is an atom in Elixir, and the
  # override's absence is the heuristic's cue.
  defp label_attr(entry, nil) do
    attrs = Info.public_attributes(entry.module)
    names = MapSet.new(attrs, & &1.name)

    Enum.find(@label_attr_order, &MapSet.member?(names, &1)) || :id
  end

  # The override honors public attributes only — a label is a value the
  # operator reads, so a non-public (or stale) name falls back to the
  # heuristic instead of exposing anything.
  defp label_attr(entry, name) when is_atom(name) do
    public = Info.public_attributes(entry.module)

    if Enum.any?(public, &(&1.name == name)) do
      name
    else
      label_attr(entry, nil)
    end
  end

  # The show page: every public attribute in declaration order. This
  # list IS the actor-safety contract — nothing else renders.
  defp fields(module) do
    module
    |> Info.public_attributes()
    |> Enum.map(&column/1)
  end

  # -- small helpers ----------------------------------------------------------

  defp resource_label(entry) do
    entry.config[:label] || AdminResource.label(entry.key)
  end

  defp record_label(record, label_name) do
    case Map.get(record, label_name) do
      nil -> AdminResource.short_uuid(record.id)
      value -> to_string(value)
    end
  end

  defp domain_cards(domain) do
    resources =
      Enum.map(domain.resources, fn resource ->
        config = resource.config

        %{
          key: resource.key,
          label: config[:label] || AdminResource.label(resource.key),
          note: config[:note]
        }
      end)

    %{key: domain.key, label: domain.label, resources: resources}
  end

  defp index_path(entry), do: ~p"/admin/resources/#{entry.domain.key}/#{entry.key}"

  defp show_path(domain_key, resource_key, id),
    do: ~p"/admin/resources/#{domain_key}/#{resource_key}/#{id}"

  # The sidebar's console nav state (D3 revised): the active domain
  # whose group renders open, and the active resource leaf with its
  # page/location truth. The landing passes nil — every group renders
  # collapsed, no leaf marked.
  defp console_nav(%{live_action: :domains}), do: nil

  defp console_nav(%{live_action: :domain, domain: domain}),
    do: %{domain: domain.key, resource: nil, exact: false}

  defp console_nav(%{live_action: :index, domain_key: domain, resource_key: resource}),
    do: %{domain: domain, resource: resource, exact: true}

  defp console_nav(%{domain_key: domain, resource_key: resource}),
    do: %{domain: domain, resource: resource, exact: false}

  defp save_flash(:new), do: gettext("The record was created.")
  defp save_flash(:edit), do: gettext("The record was updated.")

  # ?page=N — anything but a positive integer reads as page one, and a
  # parsed integer is capped before the offset math: a crafted 19-digit
  # page must not reach arithmetic as a bignum.
  @page_bound 10_000

  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {number, ""} when number >= 1 -> min(number, @page_bound)
      _not_a_positive_integer -> 1
    end
  end

  defp parse_page(_not_a_string), do: 1

  # The honest-unknown posture the other admin surfaces use (the
  # size-edit idiom): URL segments that can never exist flash and
  # bounce to the registry's real pages. A raise here would fight the
  # LiveView lifecycle (the initial render has no conn to 404 through).
  defp bounce_unknown(socket) do
    {:ok,
     socket
     |> put_flash(:error, gettext("That page does not exist here."))
     |> push_navigate(to: ~p"/admin/resources")}
  end

  # -- band copy -----------------------------------------------------------

  defp page_title(%{live_action: :domains}), do: gettext("Resource console")
  defp page_title(%{live_action: :domain, domain: domain}), do: domain.label
  defp page_title(%{live_action: :index, resource_label: label}), do: label
  defp page_title(%{live_action: :show, record_label: label}), do: label

  defp page_title(%{live_action: :new, resource_label: label}),
    do: gettext("New %{name}", name: label)

  defp page_title(%{live_action: :edit, resource_label: label}),
    do: gettext("Edit %{name}", name: label)

  defp page_intro(%{live_action: :domains}) do
    gettext(
      "Every domain the console exposes, with its resources and every public field. The raw tables behind the curated sections."
    )
  end

  defp page_intro(%{live_action: :domain}) do
    gettext(
      "The resources this domain exposes. Reads run through the resource policies with your account as the actor."
    )
  end

  defp page_intro(%{live_action: :index}) do
    gettext(
      "Every row, newest first, 25 to a page. Reads run through the resource policies with your account as the actor."
    )
  end

  defp page_intro(%{live_action: :show}) do
    gettext(
      "Every public attribute of this record. Non-public attributes never render on this surface."
    )
  end

  defp page_intro(%{live_action: :new}) do
    gettext(
      "Every write runs through the resource policies with your account as the actor. Invalid fields say so beside themselves."
    )
  end

  defp page_intro(%{live_action: :edit}) do
    gettext(
      "Every write runs through the resource policies with your account as the actor. Invalid fields say so beside themselves."
    )
  end

  defp parent_path(%{live_action: :domain}), do: ~p"/admin/resources"
  defp parent_path(%{live_action: :index, domain_key: key}), do: ~p"/admin/resources/#{key}"

  defp parent_path(%{live_action: :show, index_path: path}), do: path

  defp parent_path(%{live_action: :new, index_path: path}), do: path
  defp parent_path(%{live_action: :edit, index_path: path}), do: path

  defp parent_copy(%{live_action: :domain}), do: gettext("Back to the domains")

  defp parent_copy(%{live_action: :index, domain_label: label}),
    do: gettext("Back to %{name}", name: label)

  defp parent_copy(%{live_action: :show, resource_label: label}) do
    gettext("Back to %{name}", name: label)
  end

  defp parent_copy(%{live_action: :new, resource_label: label}),
    do: gettext("Back to %{name}", name: label)

  defp parent_copy(%{live_action: :edit, resource_label: label}),
    do: gettext("Back to %{name}", name: label)

  # -- the shared form (both write mounts) ------------------------------------

  # One form component for :new and :edit: identical machinery, only
  # the submit label differs. Per-field errors ride the form data
  # protocol through <.input>; the disable fence stops a double submit
  # at the wire.
  attr(:form, :any, required: true)
  attr(:fields, :list, required: true)
  attr(:submit, :string, required: true)

  defp record_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="admin-resource-record-form"
      phx-change="validate"
      phx-submit="save"
      class="space-y-4"
    >
      <div :for={field <- @fields} data-testid={"admin-resource-input-#{field.name}"}>
        <.input
          field={@form[field.name]}
          type={field.type}
          options={field.options}
          step={field.step}
          label={field.label}
          required={field.required}
        />
      </div>
      <.button
        type="submit"
        phx-disable-with={gettext("Saving...")}
        data-testid="admin-resource-save"
      >
        {@submit}
      </.button>
    </.form>
    """
  end
end
