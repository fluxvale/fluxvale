defmodule FluxValeWeb.EdgeTouchController do
  @moduledoc """
  The activity beacon (#203, ADR-0036): Traefik's forwardAuth consults
  this on every forwarded request to a serving instance — the edge
  middleware writing per-instance last-used markers, exactly as the
  issue settled (idle detection at the edge, never in-pod: a sleeping
  pod has no metrics to read).

  Contract, in priority order:

  - never fail the forwarded request: anything unexpected answers 204
    anyway — a beacon outage must not 500 an owner's app (the ADR-0036
    blast-radius note owns the platform-down case; this handler owns
    everything else).
  - probes and uptime monitors (Edge.probe_request?/1) never mark the
    idle clock — the settled "must NOT count as traffic" decision.
  - marks are debounced (Edge.Activity): one write per window.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Edge

  require Logger

  # Any verb: Traefik's forwardAuth issues the auth request with the
  # original method's shape at minimum, and the beacon is method-blind.
  def touch(conn, params) do
    ua_headers = get_req_header(conn, "user-agent")
    user_agent = List.first(ua_headers)

    cond do
      Edge.probe_request?(user_agent) ->
        # Settled: probes must not count as traffic. 204 either way —
        # the probe's own request proceeds; only the clock stays still.
        send_resp(conn, :no_content, "")

      instance_id = params["instance"] ->
        mark(instance_id)
        send_resp(conn, :no_content, "")

      true ->
        # A middleware without its instance param is platform drift —
        # the beacon must still answer 204 (see moduledoc).
        Logger.warning("edge touch without instance param: #{inspect(params)}")
        send_resp(conn, :no_content, "")
    end
  end

  # A failed mark (stale middleware on a deleted instance, a DB blip)
  # logs and moves on — the window stays open, the next touch retries
  # (Edge.Activity's failure posture).
  defp mark(instance_id) do
    case Edge.Activity.mark(instance_id) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning("edge touch: marking #{instance_id} failed (#{inspect(reason)})")
    end
  end
end
