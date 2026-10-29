defmodule FluxValeWeb.AccessWakeController do
  @moduledoc """
  The gateway's asleep target (#273, ADR-0039 §6): while an attached
  private instance sleeps, its serve entry points here, so a request
  through the owner's tailnet wakes the app instead of meeting serve's
  honest 502.

  Serve proxies the visitor's path onto this prefix (path and query
  append, so deep links survive), and the PAIRING in the path is the
  whole authorization (§6): the `access_routes` row is the owner's
  consent that this gateway may start this instance, so the endpoint
  needs no second credential and grants nothing panel-shaped. Every
  non-pairing miss — unknown or garbage ids, a missing row, a suspended
  gateway, a public instance, a cross-org pair — reads the identical
  `404 "not found"`: no existence or posture leak (the EdgeWake
  private-gate stance).

  Answers by status, mirroring EdgeWake's decision table with one
  difference: **no redirect, ever**. Serve owns the routing — once the
  config flips, the visitor's next refresh lands on the app on its own;
  until then this endpoint keeps serving the waking page ("still waking"
  is honest through the propagation window, §6's stated cost).

  Non-HTML clients (API callers, rclone) never get the page — 503 +
  Retry-After is the retryable honest answer; the wake still triggers.
  """

  use FluxValeWeb, :controller

  alias Ash.Type.UUID
  alias FluxVale.Edge
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessProvider
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance

  require Logger

  @refresh_seconds 2
  # The status page polls slower than the wake page: those states resolve
  # in tens of seconds (a restore, a stop), not two.
  @status_refresh_seconds 30

  def wake(conn, %{"gateway_id" => raw_gateway_id, "instance_id" => raw_instance_id}) do
    ua = user_agent(conn)

    with {:ok, gateway_id} <- cast_id(raw_gateway_id),
         {:ok, instance_id} <- cast_id(raw_instance_id),
         {:ok, pair} <- authorized_pair(gateway_id, instance_id) do
      # The probe check rides AFTER the pair gate (the EdgeWake
      # marker-first stance): a probe-shaped request against a
      # non-pairing path is just an unmatched request — 404, not a
      # phantom "asleep" that would leak a pairing's existence.
      cond do
        Edge.probe_request?(ua) ->
          # Probes must not count as traffic, and an asleep app IS down
          # to a monitor — but they must never wake anything either.
          send_resp(conn, :service_unavailable, "asleep")

        conn.method != "GET" ->
          # The wake still triggers; the BODY cannot be replayed by a
          # meta refresh, so submissions get the honest retry signal.
          wake_then_retry(conn, pair)

        true ->
          answer(conn, pair)
      end
    else
      _not_a_pairing ->
        send_resp(conn, :not_found, "not found")
    end
  end

  # ------------------------------------------------------------------
  # The pairing gate (ADR-0039 §6): the row, not the caller
  # ------------------------------------------------------------------

  # The URL names the pairing; the row IS the owner's consent, so this
  # read runs `authorize?: false` — the EdgeWake precedent (an anonymous
  # endpoint has no actor; what holds is that the request must name a
  # real, same-org, private, actively-served pairing).
  defp authorized_pair(gateway_id, instance_id) do
    with {:ok, route} <- AccessRoute.get_by_pair(gateway_id, instance_id, authorize?: false),
         # The load returns the ROUTE with its gateway populated.
         {:ok, route} <- Ash.load(route, :gateway, authorize?: false),
         gateway = route.gateway,
         :ok <- gateway_serving?(gateway),
         {:ok, instance} <- Instance.get_by_id(instance_id, authorize?: false),
         :ok <- same_org_private?(gateway, instance) do
      {:ok, {gateway, instance}}
    end
  end

  # A suspended gateway serves nothing (the ladder scaled it to 0), so
  # there is nobody behind its ports to ask — same 404 as unknown.
  defp gateway_serving?(%{state: :active}), do: :ok
  defp gateway_serving?(_gateway), do: {:error, :not_active}

  # Defense-in-depth on top of the row (the attach operation refuses a
  # cross-org or public pairing): if an out-of-band row ever said
  # otherwise, this is the backstop.
  defp same_org_private?(gateway, %{exposure: :private, organization_id: org_id})
       when org_id == gateway.organization_id,
       do: :ok

  defp same_org_private?(_gateway, _not_a_private_same_org_pair),
    do: {:error, :not_pairable}

  # Garbage in the path is the same 404 as an unknown pair, never a 500:
  # both ids are cast before any query runs.
  defp cast_id(raw) do
    case UUID.cast_input(raw, []) do
      {:ok, id} -> {:ok, id}
      _error -> {:error, :invalid_id}
    end
  end

  # ------------------------------------------------------------------
  # The status table (the EdgeWake mirror, minus the redirect)
  # ------------------------------------------------------------------

  defp answer(conn, {_gateway, %{status: :sleeping} = instance}) do
    # The funded gate decides the copy: an unfunded sleep never wakes,
    # and "retry" would be a lie (#124's gate — waking it would re-enter
    # the ladder's stop arm).
    case Infrastructure.wake_instance(instance) do
      {:ok, _waking} ->
        waking_response(conn, instance)

      {:error, :unfunded} ->
        unfunded_signal(conn)
    end
  end

  defp answer(conn, {_gateway, %{status: :starting} = instance}) do
    # Already waking — no re-trigger.
    waking_response(conn, instance)
  end

  defp answer(conn, {gateway, %{status: :running} = instance}) do
    debounced_flip(gateway, instance)

    # KEEP the waking page — the flip's whole point (§6): the mounted
    # Secret reaches the pod within seconds (worst: the kubelet's sync
    # period), and the next refresh is served by the app itself. A
    # throttled or failed attempt changes nothing: the config still
    # targets here, and the next window retries (the RestoreServingEdge
    # self-healing stance).
    waking_response(conn, instance)
  end

  defp answer(conn, {_gateway, %{status: :restoring}}) do
    # A restore owns the instance (scaled to 0, volume being rewritten):
    # a wake would serve a half-written app. The page refreshes so a
    # visitor mid-restore lands on the app when it returns.
    respond(
      conn,
      :service_unavailable,
      "This app is having a backup restored — it will be back when that finishes.",
      refresh_seconds: @status_refresh_seconds
    )
  end

  defp answer(conn, {_gateway, _other_status}) do
    # The other statuses (:stopped, :error, :deploying) resolve on their
    # own (the owner's Start, a retry) — the page claims it keeps
    # checking, so it must carry a refresh.
    respond(conn, :service_unavailable, "this app isn't serving requests right now",
      refresh_seconds: @status_refresh_seconds
    )
  end

  # The non-GET arm runs the same wake/flip decision, then 503 +
  # Retry-After: a meta refresh cannot replay a request body, so a
  # submission must be resent, never silently dropped by a page.
  defp wake_then_retry(conn, {_gateway, %{status: :sleeping} = instance}) do
    case Infrastructure.wake_instance(instance) do
      {:ok, _waking} -> retry_signal(conn)
      {:error, :unfunded} -> unfunded_signal(conn)
    end
  end

  defp wake_then_retry(conn, {gateway, %{status: :running} = instance}) do
    debounced_flip(gateway, instance)
    retry_signal(conn)
  end

  defp wake_then_retry(conn, _already_waking_or_otherwise), do: retry_signal(conn)

  # One serve-config apply per window per instance (Edge.Activity): the
  # endpoint is anonymous, and an unthrottled GET loop must not become
  # unthrottled K8s writes. A throttled window treats "someone else just
  # applied" as success — the regeneration is idempotent, and the next
  # window retries.
  defp debounced_flip(gateway, instance) do
    if Edge.Activity.claim_access_flip(instance.id) == :proceed do
      case AccessProvider.impl_for(gateway).refresh_routes(gateway) do
        {:ok, _serve_config} ->
          :ok

        # Silent would strand the visitor on a waking page that never
        # converges and leave the operator nothing to find: the config
        # still targets here, the next window retries, and the log names
        # why. Contract-exhaustive on the behaviour's {:ok, _} |
        # {:error, _} — an off-contract shape crashes loudly instead.
        {:error, reason} ->
          Logger.warning(
            "Access wake: serve-config flip failed for instance #{instance.id}: " <>
              "#{inspect(reason)}"
          )

          :error
      end
    else
      :throttled
    end
  end

  # ------------------------------------------------------------------
  # Responses (the EdgeWake shapes)
  # ------------------------------------------------------------------

  # Both waking arms: browsers watch the interstitial, machines get
  # the retryable signal — the wake has triggered either way.
  defp waking_response(conn, instance) do
    if html_client?(conn) do
      wake_page(conn, instance)
    else
      respond(conn, :service_unavailable, "waking up — retry shortly")
    end
  end

  defp retry_signal(conn) do
    respond(conn, :service_unavailable, "waking up — resend the request shortly")
  end

  defp unfunded_signal(conn) do
    respond(conn, :service_unavailable, "asleep — the owner's balance needs a top-up to wake it")
  end

  # The interstitial: JS-free (meta refresh re-requests this endpoint
  # until serve's flipped config answers instead), styled inline — the
  # visitor's URL is the gateway's tailnet name proxied onto this
  # endpoint, so /assets would route back here while asleep. put_format:
  # the route runs no accepts plug, and render/3 needs the format.
  defp wake_page(conn, instance) do
    conn
    |> put_status(:ok)
    |> put_root_layout(html: false)
    |> put_layout(false)
    |> put_format(:html)
    |> render(:wake, refresh_seconds: @refresh_seconds, name: instance.name)
  end

  defp respond(conn, status, body, opts \\ []) do
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
      send_resp(conn, status, body)
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
end
