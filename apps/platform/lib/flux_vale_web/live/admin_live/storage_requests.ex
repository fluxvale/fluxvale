defmodule FluxValeWeb.AdminLive.StorageRequests do
  @moduledoc """
  The operator storage-request queue (#250, ADR-0046 D5/D6): requests
  above the self-service boundary, newest first, filtered by status and
  searched over the request's own fields. The section is a purpose-built
  workflow in the console's Sections (not a generic resource leaf): a
  decision (durable approve/reject) and its retryable mechanical apply.

  Every read rides `StorageRequest :queue` with the platform-admin actor
  and `authorize?: true`. The instance's decision context (status,
  allocation, cluster) is a **scoped system read** after the admin gate
  (`authorize?: false`, selected fields only) — kept as built (#250's
  shape): the blanket bypass (#644) would admit the Instance read too,
  but this queue renders decision context, not the instance table. The
  org name rides the shared `Organization :admin_lookup`; the wallet
  state rides `ActorOrgWalletFunded.org_funded?/1`.

  The demotion-window defense rides the AdminChrome per-event hook
  every admin LiveView inherits (#644's console slice, ADR-0047 D4):
  each event re-resolves the actor from the session and refuses a
  demoted one, so the write handlers below act on the FRESH struct.
  The same hook subscribes this process to `storage_requests:queue`,
  so the sidebar badge stays current on every admin page; this surface
  re-reads/re-streams its rows on the same create, decision, and apply
  notifications. No polling, no email (ADR-0046 D6).
  """

  use FluxValeWeb, :live_view

  alias FluxVale.Checks.ActorOrgWalletFunded
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Instance.StorageGrowthGuard
  alias FluxVale.Infrastructure.Operations.ResizePreview
  alias FluxVale.Infrastructure.Operations.StorageExpansion
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.Pricing
  alias FluxValeWeb.AdminComponents
  alias FluxValeWeb.AdminShell
  alias FluxValeWeb.FeedbackHTML
  alias FluxValeWeb.InstanceStatus

  require Ash.Query

  @statuses [:requested, :approved, :applied, :rejected]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    # The chrome assigns (current_user, pending_storage_requests) ride
    # the AdminChrome on_mount; this mount adds the page's own state.
    socket =
      assign(socket,
        query: "",
        status: :requested,
        statuses: @statuses,
        expanded_id: nil,
        detail: nil,
        reject_form: nil,
        search_form: to_form(%{"query" => ""}, as: :search)
      )

    {:ok, refresh_rows(socket)}
  end

  # -- events ---------------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_event("search", %{"search" => %{"query" => query}}, socket)
      when is_binary(query) do
    trimmed = String.trim(query)

    {:noreply,
     socket
     |> assign(
       query: trimmed,
       search_form: to_form(%{"query" => trimmed}, as: :search),
       expanded_id: nil,
       detail: nil,
       reject_form: nil
     )
     |> refresh_rows()}
  end

  # A crafted non-string query is a no-op, not a crash.
  def handle_event("search", _params, socket), do: {:noreply, socket}

  # All: the chip clears the status filter. Known statuses narrow to it;
  # anything else (a crafted value) leaves the filter alone.
  def handle_event("filter-status", %{"status" => ""}, socket) do
    {:noreply,
     socket
     |> assign(status: nil, expanded_id: nil, detail: nil, reject_form: nil)
     |> refresh_rows()}
  end

  def handle_event("filter-status", %{"status" => raw}, socket) do
    case parse_status(raw) do
      nil ->
        {:noreply, socket}

      status ->
        {:noreply,
         socket
         |> assign(status: status, expanded_id: nil, detail: nil, reject_form: nil)
         |> refresh_rows()}
    end
  end

  # The expansion toggle. The open re-reads the request and its decision
  # context fresh; a row deleted between the list render and the click
  # never opens a panel. The stream RESET re-renders every row from the
  # new assigns, so a prior expansion collapses.
  def handle_event("open-request", %{"id" => id}, socket) do
    if socket.assigns.expanded_id == id do
      {:noreply, refresh_rows(close_expansion(socket))}
    else
      open_detail(socket, id)
    end
  end

  # Approve is one click from the open detail: the durable decision,
  # then the retryable apply. The decision is never rolled back on a
  # failed volume patch — the row stays Approved with its error and a
  # Retry button.
  def handle_event("approve", %{"id" => id}, socket) do
    attempt_approve(socket, socket.assigns.current_user, id)
  end

  # Reject requires the member-visible feedback. The surface refuses a
  # blank one before the action sees it; the action's own required
  # validation stays the arbiter.
  def handle_event("reject", %{"reject" => %{"id" => id, "feedback" => feedback}}, socket)
      when is_binary(feedback) do
    case String.trim(feedback) do
      "" ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Feedback is required — it goes to the customer verbatim."))
         |> assign(reject_form: reject_form(feedback))
         |> refresh_rows()}

      trimmed ->
        attempt_reject(socket, socket.assigns.current_user, id, trimmed)
    end
  end

  def handle_event("reject", _params, socket), do: {:noreply, socket}

  # Retry re-runs the mechanical apply on a durable approval — no
  # decision write. Idempotent when the volume already reached target.
  def handle_event("retry", %{"id" => id}, socket) do
    attempt_retry(socket, socket.assigns.current_user, id)
  end

  # -- notifications --------------------------------------------------------

  @impl Phoenix.LiveView
  def handle_info(%Ash.Notifier.Notification{}, socket) do
    {:noreply, refresh_all(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # -- writes ---------------------------------------------------------------

  defp attempt_approve(socket, admin, id) do
    case Infrastructure.approve_storage_request(admin, id) do
      {:ok, %StorageRequest{status: :applied} = applied} ->
        refreshed = refresh_all(socket)

        {:noreply, put_flash(refreshed, :info, applied_copy(applied, socket.assigns.instances))}

      {:ok, %StorageRequest{status: :approved} = failed} ->
        refreshed = refresh_all(socket)

        {:noreply,
         put_flash(
           refreshed,
           :error,
           gettext(
             "The decision is recorded, but the volume patch failed: %{error}. Retry apply below.",
             error: failed.apply_error
           )
         )}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal_copy(error))
         |> refresh_all()}
    end
  end

  defp attempt_reject(socket, admin, id, feedback) do
    case Infrastructure.reject_storage_request(admin, id, feedback) do
      {:ok, _rejected} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Rejected. The customer sees that feedback verbatim."))
         |> refresh_all()}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal_copy(error))
         |> refresh_all()}
    end
  end

  defp attempt_retry(socket, admin, id) do
    case Infrastructure.retry_storage_request(admin, id) do
      {:ok, %StorageRequest{status: :applied} = applied} ->
        refreshed = refresh_all(socket)

        {:noreply, put_flash(refreshed, :info, applied_copy(applied, socket.assigns.instances))}

      {:ok, %StorageRequest{status: :approved} = failed} ->
        refreshed = refresh_all(socket)

        {:noreply,
         put_flash(
           refreshed,
           :error,
           gettext("The retry did not land: %{error}. Fix the cluster, then retry again.",
             error: failed.apply_error
           )
         )}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal_copy(error))
         |> refresh_all()}
    end
  end

  # -- reads ----------------------------------------------------------------

  # The queue read owns the filter, the search, the newest-first sort, and
  # the 100-row cap (the moderation/people list ruling). One page plus its
  # countable count; `more?` answers the overflow copy without a second
  # query.
  defp refresh_rows(socket) do
    admin = socket.assigns.current_user
    args = queue_args(socket.assigns.status, socket.assigns.query)

    case StorageRequest.queue(args, actor: admin) do
      {:ok, page} ->
        socket
        |> assign(
          instances: instance_map(page.results),
          orgs: org_map(admin, page.results),
          requesters: requester_map(admin, page.results),
          rows_empty?: page.results == [],
          rows_more?: page.more?
        )
        |> stream(:requests, page.results, reset: true)

      # coveralls-ignore-start - the DB-down class; the admin gate admits
      # only platform admins, and a real outage surfaces on every read.
      {:error, _reason} ->
        socket
        |> put_flash(:error, gettext("The queue did not load. Try again."))
        |> stream(:requests, [], reset: true)
        |> assign(rows_empty?: true, rows_more?: false)

        # coveralls-ignore-stop
    end
  end

  defp queue_args(status, ""), do: %{status: status}

  defp queue_args(status, query), do: %{status: status, search: query}

  # The decision context: a scoped system read AFTER the admin gate
  # (the request's own read policy already admitted the operator). Only
  # the fields the decision renders — identity, status, allocation,
  # cluster — are selected; nothing technical rides the queue.
  defp instance_map([]), do: %{}

  defp instance_map(requests) do
    ids =
      requests
      |> Enum.map(& &1.instance_id)
      |> Enum.uniq()

    query =
      Instance
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([
        :id,
        :name,
        :status,
        :storage_gb,
        :cluster_id,
        :cpu_cores,
        :memory_mb,
        :app_version_id
      ])

    fetched = Ash.read!(query, authorize?: false)

    Map.new(fetched, fn instance -> {instance.id, instance} end)
  end

  defp org_map(_admin, []), do: %{}

  defp org_map(admin, requests) do
    ids =
      requests
      |> Enum.map(& &1.organization_id)
      |> Enum.uniq()

    input =
      Ash.ActionInput.for_action(FluxVale.Accounts.Organization, :admin_lookup, %{ids: ids},
        actor: admin
      )

    {:ok, orgs} = Ash.run_action(input)

    Map.new(orgs, fn org -> {org.id, org} end)
  end

  defp requester_map(_admin, []), do: %{}

  defp requester_map(admin, requests) do
    ids =
      requests
      |> Enum.map(& &1.requested_by_user_id)
      |> Enum.uniq()

    query =
      FluxVale.Identity.User
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :username])

    fetched = Ash.read!(query, actor: admin)

    Map.new(fetched, fn user -> {user.id, user.username} end)
  end

  # The expansion's fresh truth, one read set: the request (re-authorized),
  # its scoped instance context, the funded gate, the capability probe, and
  # the charged-rate preview.
  defp open_detail(socket, id) do
    case load_detail(socket, id) do
      {:ok, detail} ->
        {:noreply,
         socket
         |> assign(expanded_id: id, detail: detail, reject_form: reject_form(""))
         |> refresh_rows()}

      {:error, :gone} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That request is gone. The queue is refreshed."))
         |> close_expansion()
         |> refresh_rows()}
    end
  end

  defp load_detail(socket, id) do
    admin = socket.assigns.current_user

    case StorageRequest.get_by_id(id, actor: admin) do
      {:ok, request} ->
        instance = system_instance(request.instance_id)

        {:ok,
         %{
           request: request,
           instance: instance,
           wallet_funded?: ActorOrgWalletFunded.org_funded?(request.organization_id),
           capability: capability(instance),
           preview: preview(instance, request),
           approve_blocker: approve_blocker(request, instance)
         }}

      {:error, _gone} ->
        {:error, :gone}
    end
  end

  defp system_instance(instance_id) do
    query =
      Instance
      |> Ash.Query.filter(id == ^instance_id)
      |> Ash.Query.select([
        :id,
        :name,
        :status,
        :storage_gb,
        :cluster_id,
        :cpu_cores,
        :memory_mb,
        :app_version_id
      ])

    case Ash.read_one(query, authorize?: false) do
      {:ok, instance} ->
        instance

      # The request's FK cascades, so a nil read is the same defensive
      # race the apply's vanished-instance arm owns; the row's detail
      # renders the gone state either way.
      # coveralls-ignore-next-line
      {:error, _reason} ->
        nil
    end
  end

  # The request's FK cascades with the instance, so a request reading
  # without its instance is the defensive race the apply's
  # vanished-instance arm owns; no sequential test can stage it.
  # coveralls-ignore-next-line
  defp capability(nil), do: nil

  defp capability(instance) do
    StorageExpansion.capable?(%{cluster_id: instance.cluster_id})
  end

  # coveralls-ignore-next-line
  defp preview(nil, _request), do: :unavailable

  defp preview(instance, request) do
    allocation = %{
      cpu_cores: instance.cpu_cores,
      memory_mb: instance.memory_mb,
      storage_gb: request.requested_gb
    }

    case ResizePreview.call(instance, allocation) do
      {:ok, %{running_cents: cents}} -> {:ok, cents}
      # Unpriced and a failed pricing read both read as the advisory
      # "confirmed at approval" — never a guessed number.
      _unpriced_or_error -> :unavailable
    end
  end

  # The approve gate's honest reasons, in the action's own order — the
  # operator sees what to fix before the click, while the action remains
  # the arbiter.
  defp approve_blocker(%{status: status}, _instance) when status != :requested do
    gettext("Only a requested request can be approved.")
  end

  # The cascading FK makes the vanished instance a race no sequential
  # test can stage; the copy stays honest.
  # coveralls-ignore-start
  defp approve_blocker(_request, nil) do
    gettext("The instance no longer exists. Reject this request with feedback.")
  end

  # coveralls-ignore-stop

  defp approve_blocker(request, instance) do
    cond do
      not StorageGrowthGuard.legal_status?(instance.status) ->
        gettext("The instance is %{status}; storage can't be approved in that state.",
          status: InstanceStatus.label(instance.status)
        )

      instance.storage_gb >= request.requested_gb ->
        gettext("The instance already has %{gb} GB. Reject this request instead.",
          gb: instance.storage_gb
        )

      true ->
        approve_gate_reason(request, instance)
    end
  end

  defp approve_gate_reason(request, instance) do
    case capability(instance) do
      {:ok, true} ->
        unless ActorOrgWalletFunded.org_funded?(request.organization_id) do
          gettext("The organization's wallet isn't funded. Top it up before approving.")
        end

      {:ok, false} ->
        gettext("Storage can't be expanded on this cluster yet. Attach capacity first.")

      {:error, _reason} ->
        gettext("The storage expansion check failed. Try again.")
    end
  end

  defp refresh_all(socket) do
    socket
    |> refresh_rows()
    |> refresh_expanded()
  end

  defp refresh_expanded(socket) do
    case socket.assigns.expanded_id do
      nil ->
        socket

      id ->
        case load_detail(socket, id) do
          {:ok, detail} ->
            assign(socket, detail: detail)

          # coveralls-ignore-start - the expanded row cannot vanish
          # between refresh_rows and this re-read in the same tick;
          # another process deleting it mid-write is the DB-down race.
          {:error, :gone} ->
            close_expansion(socket)
            # coveralls-ignore-stop
        end
    end
  end

  defp close_expansion(socket) do
    assign(socket, expanded_id: nil, detail: nil, reject_form: nil)
  end

  defp reject_form(feedback) do
    to_form(%{"feedback" => feedback}, as: :reject)
  end

  # -- display helpers ------------------------------------------------------

  defp parse_status(raw) when is_binary(raw) do
    Enum.find(@statuses, fn status -> Atom.to_string(status) == raw end)
  end

  defp parse_status(_other), do: nil

  defp org_label(orgs, organization_id) do
    case Map.fetch(orgs, organization_id) do
      {:ok, org} ->
        org.name

      # The org FK restricts deletion, so a missing name is the
      # defensive DB-down class.
      # coveralls-ignore-start
      :error ->
        gettext("Unknown org")
        # coveralls-ignore-stop
    end
  end

  defp requester_label(requesters, user_id) do
    Map.get(requesters, user_id, gettext("Unknown requester"))
  end

  defp instance_label(instances, instance_id) do
    case Map.fetch(instances, instance_id) do
      {:ok, %{name: name}} ->
        name

      # The FK cascades with the instance, so this is the defensive
      # vanished-row race.
      # coveralls-ignore-start
      :error ->
        gettext("Unknown instance")
        # coveralls-ignore-stop
    end
  end

  defp applied_copy(request, instances) do
    gettext("Applied — %{gb} GB on %{instance}.",
      gb: request.requested_gb,
      instance: instance_label(instances, request.instance_id)
    )
  end

  defp refusal_copy(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, "; ", &Exception.message/1)
  end

  # coveralls-ignore-start - defensive: the operations answer an Ash
  # error today (the guards' refusals, a vanished request); another
  # exception class still reads honestly instead of crashing the queue.
  defp refusal_copy(error), do: Exception.message(error)
  # coveralls-ignore-stop

  defp status_label(:requested), do: gettext("Requested")
  defp status_label(:approved), do: gettext("Approved")
  defp status_label(:applied), do: gettext("Applied")
  defp status_label(:rejected), do: gettext("Rejected")

  defp status_tone(:requested), do: "warning"
  defp status_tone(:approved), do: "primary"
  defp status_tone(:applied), do: "success"
  defp status_tone(:rejected), do: "danger"

  defp rate_text(nil), do: gettext("—")
  defp rate_text(cents), do: Pricing.format_usd(cents) <> "/mo"

  defp preview_text(:unavailable), do: gettext("Price confirmed at approval")
  defp preview_text({:ok, cents}), do: rate_text(cents)

  # coveralls-ignore-next-line - the nil-instance race (see capability/1)
  defp capability_text(nil), do: gettext("No instance to probe")
  defp capability_text({:ok, true}), do: gettext("Expansion available")
  defp capability_text({:ok, false}), do: gettext("Expansion unavailable")
  defp capability_text({:error, _reason}), do: gettext("Expansion check failed")

  defp capability_tone({:ok, true}), do: "success"
  defp capability_tone({:ok, false}), do: "danger"
  defp capability_tone({:error, _reason}), do: "warning"
  # coveralls-ignore-next-line - the nil-instance race (see capability/1)
  defp capability_tone(nil), do: "neutral"

  defp wallet_text(true), do: gettext("Wallet funded")
  defp wallet_text(false), do: gettext("Wallet not funded")

  defp wallet_tone(true), do: "success"
  defp wallet_tone(false), do: "danger"

  defp stamp_text(%DateTime{} = stamp), do: Calendar.strftime(stamp, "%b %d, %Y")

  # -- render ---------------------------------------------------------------

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
      - flush sidebar, the surface fills the space beside it. --%>
      <div class="appgram console contents" data-testid="admin-storage-requests">
        <section class="band">
          <div class="wrap pt-8 pb-10">
            <div class="rise">
              <p class="eyebrow">{gettext("Operator console")}</p>
              <h1 class="page-title mt-1.5">{gettext("Storage requests")}</h1>
              <p class="mt-2 max-w-prose text-base text-ink-muted">
                {gettext(
                  "Requests above the self-service boundary. Order and attach the capacity first, then approve; the volume grows online and the decision stands even when the patch has to be retried."
                )}
              </p>
            </div>
          </div>
        </section>

        <section class="wrap pt-8 pb-16">
          <div class="rise flex flex-col gap-8 md:flex-row md:gap-12">
            <AdminShell.sidebar
              current="storage-requests"
              pending_requests={@pending_storage_requests}
            />

            <div class="min-w-0 flex-1 space-y-6" data-testid="admin-storage-requests-content">
              <div class="space-y-4" data-testid="admin-storage-requests-toolbar">
                <.card class="space-y-4" data-testid="admin-storage-requests-search-card">
                  <div>
                    <h2 class="text-base font-medium text-ink">{gettext("Find a request")}</h2>
                    <p class="mt-1 text-sm text-ink-muted">
                      {gettext("Search the reason text or an exact request or instance id.")}
                    </p>
                  </div>
                  <.form
                    for={@search_form}
                    id="admin-storage-requests-search"
                    phx-change="search"
                    phx-submit="search"
                  >
                    <.input
                      field={@search_form[:query]}
                      type="text"
                      label={gettext("Search")}
                      placeholder={gettext("Reason, request id, or instance id")}
                      phx-debounce="200"
                      data-testid="admin-storage-requests-search-input"
                    />
                  </.form>
                </.card>

                <div
                  class="flex flex-wrap items-center gap-2"
                  role="group"
                  aria-label={gettext("Filter by status")}
                  data-testid="admin-storage-requests-status-filter"
                >
                  <button
                    :for={status <- @statuses}
                    type="button"
                    phx-click="filter-status"
                    phx-value-status={Atom.to_string(status)}
                    aria-pressed={if @status == status, do: "true", else: "false"}
                    class={[
                      "inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-medium motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
                      @status == status && "border-primary/25 bg-primary-muted text-link",
                      @status != status && "border-line bg-panel text-ink-muted hover:text-ink"
                    ]}
                    data-testid={"admin-storage-requests-filter-#{status}"}
                  >
                    {status_label(status)}
                    <span
                      :if={status == :requested}
                      class={[
                        "rounded-full px-1.5 text-[11px] font-semibold",
                        @status == status && "bg-primary/15 text-link",
                        @status != status && "bg-panel-raised text-ink-subtle"
                      ]}
                      data-testid="admin-storage-requests-count-requested"
                    >
                      {@pending_storage_requests}
                    </span>
                  </button>

                  <button
                    type="button"
                    phx-click="filter-status"
                    phx-value-status=""
                    aria-pressed={if is_nil(@status), do: "true", else: "false"}
                    class={[
                      "rounded-full border px-3 py-1 text-xs font-medium motion-safe:transition-colors motion-safe:duration-(--motion-fast)",
                      is_nil(@status) && "border-primary/25 bg-primary-muted text-link",
                      not is_nil(@status) && "border-line bg-panel text-ink-muted hover:text-ink"
                    ]}
                    data-testid="admin-storage-requests-filter-all"
                  >
                    {gettext("All")}
                  </button>
                </div>
              </div>

              <div class="space-y-4" data-testid="admin-storage-requests-list">
                <%!-- The cap is the queue read's page size (100); the copy
                is kept literal (a module attribute reads as assigns in
                HEEx). Move the two together. --%>
                <p
                  :if={@rows_more?}
                  class="text-sm text-ink-muted"
                  data-testid="admin-storage-requests-more"
                >
                  {gettext("Showing the latest 100 requests.")}
                </p>

                <div
                  :if={@rows_empty?}
                  class="rounded-panel border border-line bg-panel px-6 py-8"
                  data-testid="admin-storage-requests-empty"
                >
                  <.empty_state
                    :if={@query == "" and @status == :requested}
                    title={gettext("No requests waiting.")}
                    class="border-none bg-transparent"
                  >
                    {gettext("New requests land here the moment a member asks.")}
                  </.empty_state>

                  <.empty_state
                    :if={@query != "" or @status != :requested}
                    title={gettext("No request matches that search or filter.")}
                    class="border-none bg-transparent"
                  />
                </div>

                <div :if={not @rows_empty?} class="rounded-panel border border-line bg-panel text-ink">
                  <div class={[
                    "grid-cols-[minmax(0,1fr)_7rem_7rem_5rem_6rem_4.5rem]",
                    AdminComponents.admin_table_header_class()
                  ]}>
                    <div>{gettext("Request")}</div>
                    <div>{gettext("Storage")}</div>
                    <div>{gettext("Requester")}</div>
                    <div>{gettext("Rate")}</div>
                    <div>{gettext("Status")}</div>
                    <div class="sr-only">{gettext("Actions")}</div>
                  </div>

                  <div id="admin-storage-requests-rows" phx-update="stream">
                    <div
                      :for={{dom_id, request} <- @streams.requests}
                      id={dom_id}
                      class="border-b border-line last:border-0"
                    >
                      <div class={[
                        "grid-cols-[minmax(0,1fr)_7rem_7rem_5rem_6rem_4.5rem]",
                        AdminComponents.admin_table_row_class()
                      ]}>
                        <div class="min-w-0">
                          <p
                            class="text-sm font-medium text-ink [overflow-wrap:anywhere]"
                            data-testid={"admin-storage-requests-instance-#{request.id}"}
                          >
                            {instance_label(@instances, request.instance_id)}
                          </p>
                          <p
                            class="mt-0.5 truncate text-xs text-ink-muted"
                            data-testid={"admin-storage-requests-org-#{request.id}"}
                          >
                            {org_label(@orgs, request.organization_id)}
                          </p>
                          <p
                            class="mt-1 text-xs text-ink-muted [overflow-wrap:anywhere]"
                            data-testid={"admin-storage-requests-reason-#{request.id}"}
                          >
                            {request.reason}
                          </p>
                        </div>
                        <div class="text-sm">
                          <span data-testid={"admin-storage-requests-storage-#{request.id}"}>
                            {request.current_storage_gb} → {request.requested_gb} GB
                          </span>
                          <p class="mt-0.5 text-xs text-ink-muted">
                            +{request.requested_gb - request.current_storage_gb} GB
                          </p>
                        </div>
                        <div class="min-w-0">
                          <p
                            class="truncate text-sm text-ink"
                            data-testid={"admin-storage-requests-requester-#{request.id}"}
                          >
                            {requester_label(@requesters, request.requested_by_user_id)}
                          </p>
                          <p class="mt-0.5 text-xs text-ink-muted">
                            {FeedbackHTML.time_ago(request.created_at)}
                          </p>
                        </div>
                        <div class="text-sm">
                          <span data-testid={"admin-storage-requests-rate-#{request.id}"}>
                            {rate_text(request.quoted_monthly_cents)}
                          </span>
                        </div>
                        <div>
                          <span data-testid={"admin-storage-requests-status-#{request.id}"}>
                            <.badge tone={status_tone(request.status)} class="px-1.5! text-[11px]!">
                              {status_label(request.status)}
                            </.badge>
                          </span>
                        </div>
                        <div>
                          <div class="flex items-center justify-end">
                            <.button
                              size="sm"
                              variant="secondary"
                              phx-click="open-request"
                              phx-value-id={request.id}
                              phx-disable-with={gettext("Opening...")}
                              data-testid={"admin-storage-requests-expand-#{request.id}"}
                            >
                              <%= if @expanded_id == request.id do %>
                                {gettext("Close")}
                              <% else %>
                                {gettext("Expand")}
                              <% end %>
                            </.button>
                          </div>
                        </div>
                      </div>

                      <%!-- The failed apply's honest detail rides the row:
                      the decision is durable, the mechanical step is not. --%>
                      <div
                        :if={request.apply_error}
                        class="border-t border-line-danger bg-danger-muted px-4 py-2"
                        data-testid={"admin-storage-requests-error-#{request.id}"}
                      >
                        <p class="text-xs text-danger-deep [overflow-wrap:anywhere]">
                          {gettext("Apply failed: %{error}", error: request.apply_error)}
                        </p>
                      </div>

                      <div
                        :if={@expanded_id == request.id && @detail}
                        id={"admin-storage-requests-detail-#{request.id}"}
                        class="space-y-5 border-t border-line px-4 pb-4 pt-4"
                        data-testid={"admin-storage-requests-detail-#{request.id}"}
                      >
                        <.detail_body
                          detail={@detail}
                          instances={@instances}
                          orgs={@orgs}
                          requesters={@requesters}
                          reject_form={@reject_form}
                        />
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:detail, :map, required: true)
  attr(:instances, :map, required: true)
  attr(:orgs, :map, required: true)
  attr(:requesters, :map, required: true)
  attr(:reject_form, :any, required: true)

  defp detail_body(assigns) do
    request = assigns.detail.request
    instance = assigns.detail.instance

    assigns =
      assign(assigns,
        request: request,
        instance: instance,
        approve_blocker: assigns.detail.approve_blocker,
        capability: assigns.detail.capability,
        preview: assigns.detail.preview,
        wallet_funded?: assigns.detail.wallet_funded?
      )

    ~H"""
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-ink-muted">
      <.badge tone={status_tone(@request.status)} data-testid="admin-storage-request-status">
        {status_label(@request.status)}
      </.badge>
      <span>{gettext("Submitted %{ago}", ago: FeedbackHTML.time_ago(@request.created_at))}</span>
      <span :if={@request.decided_at}>
        {gettext("Decided %{date}", date: stamp_text(@request.decided_at))}
      </span>
      <span :if={@request.applied_at}>
        {gettext("Applied %{date}", date: stamp_text(@request.applied_at))}
      </span>
    </div>

    <dl class="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Instance")}
        </dt>
        <dd class="mt-0.5 text-ink" data-testid="admin-storage-request-instance">
          {instance_label(@instances, @request.instance_id)}
        </dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Organization")}
        </dt>
        <dd class="mt-0.5 text-ink" data-testid="admin-storage-request-org">
          {org_label(@orgs, @request.organization_id)}
        </dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Requested by")}
        </dt>
        <dd class="mt-0.5 text-ink" data-testid="admin-storage-request-requester">
          {requester_label(@requesters, @request.requested_by_user_id)}
        </dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Quoted rate")}
        </dt>
        <dd class="mt-0.5 text-ink" data-testid="admin-storage-request-quote">
          {rate_text(@request.quoted_monthly_cents)}
        </dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Instance status")}
        </dt>
        <dd class="mt-0.5" data-testid="admin-storage-request-instance-status">
          <%= if @instance do %>
            <.status_badge status={@instance.status} />
          <% else %>
            <%!-- coveralls-ignore-start - the FK cascade means a request
            never outlives its instance; the defensive race renders the
            gone state honestly. --%>
            <span class="text-sm text-ink-muted">{gettext("Instance gone")}</span>
            <%!-- coveralls-ignore-stop --%>
          <% end %>
        </dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Live allocation")}
        </dt>
        <dd class="mt-0.5 text-ink" data-testid="admin-storage-request-allocation">
          <%= if @instance do %>
            {AdminComponents.instance_allocation_text(@instance)}
          <% else %>
            <%!-- coveralls-ignore-start - see the instance-status nil arm --%>
            {gettext("—")}
            <%!-- coveralls-ignore-stop --%>
          <% end %>
        </dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Capacity")}
        </dt>
        <dd class="mt-0.5" data-testid="admin-storage-request-capability">
          <.badge tone={capability_tone(@capability)}>{capability_text(@capability)}</.badge>
        </dd>
      </div>
      <div>
        <dt class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
          {gettext("Wallet")}
        </dt>
        <dd class="mt-0.5" data-testid="admin-storage-request-wallet">
          <.badge tone={wallet_tone(@wallet_funded?)}>{wallet_text(@wallet_funded?)}</.badge>
        </dd>
      </div>
    </dl>

    <div class="rounded-control border border-line bg-panel-raised px-3 py-2">
      <p class="text-sm text-ink">
        {gettext("Target rate at approval")}:
        <span class="font-medium" data-testid="admin-storage-request-preview">{preview_text(@preview)}</span>
      </p>
      <p class="mt-1 text-xs text-ink-muted">
        {gettext("The shown rate is the charged rate. The instance's clock re-anchors at approval.")}
      </p>
    </div>

    <%!-- Reject is the terminal decision and also the escape hatch for
    an approved request the infrastructure can never apply. The feedback
    is member-visible verbatim, so the form says so. --%>
    <div
      :if={@request.status in [:requested, :approved]}
      class="space-y-2"
      data-testid="admin-storage-request-reject-zone"
    >
      <h3 class="text-sm font-medium text-ink">{gettext("Reject with feedback")}</h3>
      <p class="text-xs text-ink-muted">
        {gettext("This goes to the customer verbatim.")}
      </p>
      <.form for={@reject_form} id={"admin-storage-request-reject-#{@request.id}"} phx-submit="reject">
        <input type="hidden" name="reject[id]" value={@request.id} />
        <.input
          field={@reject_form[:feedback]}
          type="textarea"
          label={gettext("Feedback")}
          rows="2"
          placeholder={gettext("Explain what the customer can do next")}
          data-testid="admin-storage-request-feedback"
        />
        <div class="mt-2 flex justify-end">
          <.button size="sm" variant="destructive" data-testid="admin-storage-request-reject">
            {gettext("Reject request")}
          </.button>
        </div>
      </.form>
    </div>

    <%!-- Approve is one click: the durable decision plus the apply. The
    confirm card names the delta, the charged rate, and the runtime
    promise. A disabled button names the reason. --%>
    <div
      :if={@request.status == :requested}
      class="space-y-2 rounded-control border border-line bg-panel-raised px-3 py-3"
      data-testid="admin-storage-request-approve-zone"
    >
      <h3 class="text-sm font-medium text-ink">{gettext("Approve and apply")}</h3>
      <p class="text-sm text-ink">
        {gettext("%{current} GB → %{requested} GB on %{instance}.",
          current: @request.current_storage_gb,
          requested: @request.requested_gb,
          instance: instance_label(@instances, @request.instance_id)
        )}
      </p>
      <p class="text-sm text-ink-muted">
        {gettext("The instance keeps running; a restart may be needed to see the new space.")}
      </p>
      <.button
        size="sm"
        disabled={@approve_blocker != nil}
        phx-click="approve"
        phx-value-id={@request.id}
        phx-disable-with={gettext("Approving...")}
        data-testid="admin-storage-request-approve"
      >
        {gettext("Approve and apply")}
      </.button>
      <p
        :if={@approve_blocker}
        class="text-xs text-warning"
        data-testid="admin-storage-request-approve-blocker"
      >
        {@approve_blocker}
      </p>
    </div>

    <%!-- The durable decision's mechanical half: a failed (or never-run)
    apply is retried here, never re-decided. --%>
    <div
      :if={@request.status == :approved}
      class="space-y-2 rounded-control border border-line bg-panel-raised px-3 py-3"
      data-testid="admin-storage-request-apply-zone"
    >
      <h3 class="text-sm font-medium text-ink">{gettext("Apply the approved growth")}</h3>
      <p
        :if={@request.apply_error}
        class="text-sm text-danger-deep"
        data-testid="admin-storage-request-apply-error"
      >
        {gettext("The last apply failed: %{error}", error: @request.apply_error)}
      </p>
      <p :if={is_nil(@request.apply_error)} class="text-sm text-ink-muted">
        {gettext("The decision is recorded; the volume patch has not run yet.")}
      </p>
      <.button
        size="sm"
        phx-click="retry"
        phx-value-id={@request.id}
        phx-disable-with={gettext("Retrying...")}
        data-testid="admin-storage-request-retry"
      >
        {gettext("Retry apply")}
      </.button>
    </div>

    <%!-- The terminal rejection's feedback is what the member sees: the
    operator's own record of the decision. --%>
    <div
      :if={@request.status == :rejected and @request.rejection_reason}
      class="rounded-control border border-line-warning bg-warning-muted px-3 py-2"
      data-testid="admin-storage-request-rejection"
    >
      <p class="text-xs font-medium uppercase tracking-wide text-ink-subtle">
        {gettext("Feedback shown to the customer")}
      </p>
      <p class="mt-1 text-sm text-ink [overflow-wrap:anywhere]">{@request.rejection_reason}</p>
    </div>
    """
  end
end
