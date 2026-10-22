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
    the reload after `:running` lands on the restored app route).
  - `:sleeping` + unfunded → 503: asleep until the org tops up (the
    #124 gate — waking it would re-enter the ladder's stop arm).
  - `:starting` → the waking page (already waking; no re-trigger).
  - `:running` → restore the serving routes, then 302 — the flip
    converges here no matter which path missed it (self-healing).
  - anything else → 503, plainly.
  - probes (Edge.probe_request?/1) → 503, never a wake: probes must
    not count as traffic, and an asleep app IS down to a monitor.

  Non-HTML clients (API callers, rclone) never get the page — 503 +
  Retry-After is the retryable honest answer; the wake still triggers.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Edge
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxValeWeb.Plugs.EdgeHost

  @refresh_seconds 2

  def wake(conn, _params) do
    # Plug normalizes incoming headers to lowercase; the canonical
    # casing is for the manifests the marker middleware carries.
    header = String.downcase(EdgeRoutes.instance_header())
    marker_headers = get_req_header(conn, header)
    instance_id = List.first(marker_headers)
    ua = user_agent(conn)

    cond do
      # Header first: a probe-shaped request without a marker is just
      # an unmatched platform request — 404, not a phantom "asleep".
      is_nil(instance_id) ->
        send_resp(conn, :not_found, "not found")

      Edge.probe_request?(ua) ->
        send_resp(conn, :service_unavailable, "asleep")

      true ->
        instance = Instance.get_by_id(instance_id, authorize?: false)
        answer(conn, instance)
    end
  end

  defp answer(conn, {:ok, %{status: :sleeping} = instance}) do
    case Infrastructure.wake_instance(instance) do
      {:ok, _waking} ->
        waking_response(conn, instance)

      {:error, :unfunded} ->
        respond(
          conn,
          :service_unavailable,
          "asleep — the owner's balance needs a top-up to wake it"
        )
    end
  end

  defp answer(conn, {:ok, %{status: :starting} = instance}) do
    waking_response(conn, instance)
  end

  defp answer(conn, {:ok, %{status: :running} = instance}) do
    # The flip converges here (see moduledoc): restore, then hand the
    # visitor back to the URL they asked for. The restore is debounced
    # (Edge.Activity) — the endpoint is public, and an unthrottled GET
    # loop must not turn into unthrottled K8s applies; a skipped apply
    # changes nothing (idempotent SSA, and the next window retries).
    case debounced_restore(instance) do
      :ok ->
        respond(conn, :found, nil, location: original_url(conn), retry_after: "1")

      {:error, _error} ->
        # Failed flip: the retry hint, not a redirect onto a route that
        # still points here (the next window retries the apply).
        respond(conn, :service_unavailable, "almost there — retrying the switch")
    end
  end

  defp answer(conn, {:ok, _other_status}) do
    respond(conn, :service_unavailable, "this app isn't serving requests right now")
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

  # Both waking arms: browsers watch the interstitial, machines get
  # the retryable signal — the wake has triggered either way.
  defp waking_response(conn, instance) do
    if html_client?(conn) do
      wake_page(conn, instance)
    else
      respond(conn, :service_unavailable, "waking up — retry shortly")
    end
  end

  # The interstitial: JS-free (meta refresh re-requests this endpoint
  # until the flip answers a redirect), styled by the platform's own
  # compiled tokens — this endpoint serves the response, so the
  # app.css link resolves. put_format: the catch-all route runs no
  # accepts plug, and render/3 needs the format.
  defp wake_page(conn, instance) do
    conn
    |> put_status(:ok)
    |> put_root_layout(html: false)
    |> put_layout(false)
    |> put_format(:html)
    |> render(:wake, refresh_seconds: @refresh_seconds, name: instance.name)
  end

  defp respond(conn, status, body, opts \\ [])

  defp respond(conn, :found = status, body, opts) do
    conn
    |> put_resp_header("location", opts[:location])
    |> maybe_html(status, body, opts)
  end

  defp respond(conn, status, body, opts) do
    conn
    |> put_resp_header("retry-after", opts[:retry_after] || "3")
    |> maybe_html(status, body, opts)
  end

  # HTML negotiation: browsers ask for text/html, machines don't —
  # browsers get the auto-refreshing page, everything else the plain
  # status line (retry clients honor Retry-After).
  defp maybe_html(conn, status, body, opts) do
    if html_client?(conn) do
      conn
      |> put_status(status)
      |> put_root_layout(html: false)
      |> put_layout(false)
      |> put_format(:html)
      |> render(:status, status: status, body: body, refresh_seconds: opts[:refresh_seconds])
    else
      send_resp(conn, status, body || "")
    end
  end

  defp html_client?(conn) do
    accept_headers = get_req_header(conn, "accept")
    accept = List.first(accept_headers)

    is_binary(accept) and String.contains?(accept, "text/html")
  end

  defp user_agent(conn) do
    ua_headers = get_req_header(conn, "user-agent")
    List.first(ua_headers)
  end

  defp original_url(conn) do
    # Back to the URL the visitor asked for (query included) — the EdgeHost
    # rewrite preserved it; the app serves it once the routes flip.
    # Router-level callers (tests) carry no rewrite: derive from the
    # prefixed path.
    case conn.private[:fluxvale_edge_original] do
      %{path: path, query: query} ->
        suffix = if query == "", do: "", else: "?#{query}"
        path <> suffix

      nil ->
        prefix = EdgeHost.prefix()
        suffix = if conn.query_string == "", do: "", else: "?#{conn.query_string}"
        String.replace_prefix(conn.request_path, prefix, "") <> suffix
    end
  end
end
