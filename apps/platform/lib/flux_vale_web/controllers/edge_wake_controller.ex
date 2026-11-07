defmodule FluxValeWeb.EdgeWakeController do
  @moduledoc """
  The wake endpoint (#203, ADR-0036): a sleeping instance's edge routes
  point here (via its `wake` ExternalName Service + marker middleware),
  so a visitor's request wakes the app instead of meeting a
  connectionless Service.

  Reached through the EdgeHost rewrite (see the plug's moduledoc for
  why a router catch-all cannot work); the platform-minted
  `X-FluxVale-Instance` header is a routing key, not an auth token
  (wake is public by design — traffic-reversible is the product).

  Answers by status, per the ADR's decision table:

  - `:sleeping` + funded + real visitor → trigger `start`, serve the
    waking page (JS-free: a 2s meta-refresh re-requests this endpoint;
    the reload after `:running` lands on the restored app route) —
    GET only: a meta refresh cannot replay a request body, so
    submissions (form POSTs, PUTs) get the retryable 503 instead of a
    page that would silently drop them.
  - `:sleeping` + unfunded → 503: asleep until the org tops up (the
    #124 gate — waking it would re-enter the ladder's stop arm).
  - `:starting` → the waking page (already waking; no re-trigger).
  - `:running` → restore the serving routes, then 302 — the flip
    converges here no matter which path missed it (self-healing).
  - `:restoring` → 503 naming the restore in plain words: a restore owns
    the instance (it is scaled to 0 and its volume is being rewritten), so
    a wake would serve a half-written app. The page refreshes.
  - anything else → 503, plainly — and the page refreshes.
  - probes (Edge.probe_request?/1) → 503, never a wake: probes must
    not count as traffic, and an asleep app IS down to a monitor.
  - **private rows → 404, always** (PR #267 review round 2): the
    endpoint is public and host-agnostic, so a forged marker naming a
    private instance must not start it (burning the owner's balance)
    or 302 at a host that never serves — the same "not found" as an
    unknown id, no posture or existence leak; the panel remains the
    only starter.

  Non-HTML clients (API callers, rclone) never get the page — 503 +
  Retry-After is the retryable honest answer; the wake still triggers.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Edge
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxValeWeb.Plugs.EdgeHost
  alias FluxValeWeb.Wake

  @refresh_seconds 2
  # The status page polls slower than the wake page: those states resolve
  # in tens of seconds (a restore, a stop, a failed start), not two.
  @status_refresh_seconds 30

  def wake(conn, _params) do
    # Plug normalizes incoming headers to lowercase; the canonical
    # casing is for the manifests the marker middleware carries.
    header = String.downcase(EdgeRoutes.instance_header())
    marker_headers = get_req_header(conn, header)
    instance_id = List.first(marker_headers)
    ua = Wake.user_agent(conn)

    cond do
      # Header first: a probe-shaped request without a marker is just
      # an unmatched platform request — 404, not a phantom "asleep".
      is_nil(instance_id) ->
        send_resp(conn, :not_found, "not found")

      Edge.probe_request?(ua) ->
        send_resp(conn, :service_unavailable, "asleep")

      conn.method != "GET" ->
        # The wake still triggers; the BODY cannot be replayed by a
        # meta refresh, so submissions get the honest retry signal.
        wake_then_retry(conn, instance_id)

      true ->
        instance = Instance.get_by_id(instance_id, authorize?: false)
        answer(conn, instance)
    end
  end

  defp wake_then_retry(conn, instance_id) do
    case Instance.get_by_id(instance_id, authorize?: false) do
      # The private gate's non-GET arm: no wake, no retry signal that
      # would name a live instance — the same 404 the GET path serves
      # (see the private clause of answer/2).
      {:ok, %Instance{exposure: :private}} ->
        send_resp(conn, :not_found, "not found")

      {:ok, %{status: :sleeping} = instance} ->
        # The wake's funded gate decides the copy: an unfunded sleep
        # never wakes, and "resend" would be a lie.
        case Infrastructure.wake_instance(instance) do
          {:ok, _waking} -> retry_signal(conn)
          {:error, :unfunded} -> unfunded_signal(conn)
        end

      {:ok, _already_waking_or_serving} ->
        retry_signal(conn)

      {:error, _not_found} ->
        send_resp(conn, :not_found, "not found")
    end
  end

  defp retry_signal(conn) do
    Wake.respond(
      conn,
      :service_unavailable,
      "waking up. Resend the request shortly",
      wake_opts(nil)
    )
  end

  defp unfunded_signal(conn) do
    Wake.respond(
      conn,
      :service_unavailable,
      "asleep. The owner's balance needs a top-up to wake it",
      wake_opts(nil)
    )
  end

  # The surface's view and the wake-page refresh cadence, for the shared
  # transport. Status pages pass their own slower refresh.
  defp wake_opts(refresh_seconds \\ @refresh_seconds) do
    [view: FluxValeWeb.EdgeWakeHTML, refresh_seconds: refresh_seconds]
  end

  # PR #267 review round 2 (P2-2): the private gate, before any status
  # logic — a forged marker must not learn the row exists, start it, or
  # be redirected at a host that never serves. Identical bytes to the
  # unknown-id answer on purpose.
  defp answer(conn, {:ok, %Instance{exposure: :private}}) do
    send_resp(conn, :not_found, "not found")
  end

  defp answer(conn, {:ok, %{status: :sleeping} = instance}) do
    case Infrastructure.wake_instance(instance) do
      {:ok, _waking} ->
        Wake.waking_response(conn, instance, wake_opts())

      {:error, :unfunded} ->
        Wake.respond(
          conn,
          :service_unavailable,
          "asleep. The owner's balance needs a top-up to wake it",
          wake_opts(nil)
        )
    end
  end

  defp answer(conn, {:ok, %{status: :starting} = instance}) do
    Wake.waking_response(conn, instance, wake_opts())
  end

  defp answer(conn, {:ok, %{status: :running} = instance}) do
    # The flip converges here (see moduledoc): restore, then hand the
    # visitor back to the URL they asked for. The restore is debounced
    # (Edge.Activity) — the endpoint is public, and an unthrottled GET
    # loop must not turn into unthrottled K8s applies; a skipped apply
    # changes nothing (idempotent SSA, and the next window retries).
    case debounced_restore(instance) do
      :ok ->
        opts = wake_opts() ++ [location: original_url(conn), retry_after: "1"]
        Wake.respond(conn, :found, nil, opts)

      {:error, _error} ->
        # Failed flip: the retry hint, not a redirect onto a route that
        # still points here (the next window retries the apply).
        Wake.respond(
          conn,
          :service_unavailable,
          "almost there. Retrying the switch",
          wake_opts(nil)
        )
    end
  end

  defp answer(conn, {:ok, %{status: :restoring}}) do
    # A restore owns the instance: it is scaled to 0 on purpose and the
    # volume is being rewritten, so a wake would put the app back on a
    # half-written volume. The page refreshes so a visitor mid-restore
    # lands on the app when it returns.
    Wake.respond(
      conn,
      :service_unavailable,
      "This app is having a backup restored. It will be back when that finishes.",
      wake_opts(@status_refresh_seconds)
    )
  end

  defp answer(conn, {:ok, _other_status}) do
    # Refresh, not a dead end: the other statuses (:stopped, :error,
    # :deploying) still resolve on their own, and the page's copy claims
    # it keeps checking — an empty refresh would make that a lie.
    Wake.respond(
      conn,
      :service_unavailable,
      "this app isn't serving requests right now",
      wake_opts(@status_refresh_seconds)
    )
  end

  defp answer(conn, {:error, _not_found}) do
    # A stale wake middleware after teardown: the row is gone; the
    # routes disappear with the namespace.
    send_resp(conn, :not_found, "not found")
  end

  # One apply per window per instance: the endpoint is public, and an
  # unthrottled GET loop must not become unthrottled K8s applies. A
  # throttled request treats "someone else just applied" as success —
  # idempotent SSA makes that true.
  defp debounced_restore(instance) do
    if Edge.Activity.claim_restore(instance.id) == :proceed do
      Infrastructure.restore_serving_edge(instance)
    else
      :ok
    end
  end

  defp original_url(conn) do
    # Back to the URL the visitor asked for (query included) — the EdgeHost
    # rewrite preserved it; the app serves it once the routes flip.
    # Router-level callers (tests) carry no rewrite: derive from the
    # prefixed path.
    target =
      case conn.private[:fluxvale_edge_original] do
        %{path: path, query: query} ->
          suffix = if query == "", do: "", else: "?#{query}"
          path <> suffix

        nil ->
          prefix = EdgeHost.prefix()
          suffix = if conn.query_string == "", do: "", else: "?#{conn.query_string}"
          String.replace_prefix(conn.request_path, prefix, "") <> suffix
      end

    local_path(target)
  end

  # Redirect targets must stay same-origin: a request path of
  # "//evil.example" (or "/\evil.example") would otherwise render a
  # Location browsers treat as off-site.
  # Defense-in-depth for router-level callers: the EdgeHost rewrite
  # normalizes real traffic's paths (its own test pins that), and
  # Plug.Test reshapes // paths before they reach a controller — the
  # arm itself isn't stageable end to end.
  # coveralls-ignore-start
  defp local_path("//" <> rest) do
    local_path("/" <> rest)
  end

  # coveralls-ignore-stop

  defp local_path("/" <> _rest = target) do
    target
  end
end
