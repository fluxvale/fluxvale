defmodule FluxValeWeb.Plugs.MetricsEndpoint do
  @moduledoc """
  Gate + dispatcher for the PromEx scrape endpoint (#98, ADR-0012).

  When :metrics_token is configured (fleet overlays set METRICS_TOKEN in
  prod-shaped runs), the request must carry `Authorization: Bearer
  <token>` — the Service annotations decide who scrapes, this decides
  who can read. Unset (dev/test), the endpoint is open on the cluster
  network.

  Exact path only: PromEx.Plug answers "/metrics" and leaves any deeper
  path unanswered (a 500); here those 404 instead.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Conn{request_path: "/metrics"} = conn, _opts) do
    case Application.get_env(:flux_vale, :metrics_token) do
      nil ->
        serve(conn)

      token ->
        if authorized?(conn, token), do: serve(conn), else: deny(conn)
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not Found")

  defp authorized?(conn, expected) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> presented] -> Plug.Crypto.secure_compare(presented, expected)
      _other -> false
    end
  end

  defp serve(conn) do
    # PromEx.Plug's clauses match on initialized opts (a map) — a raw
    # keyword falls into its pass-through catch-all and sends nothing.
    opts = PromEx.Plug.init(prom_ex_module: FluxVale.PromEx)

    PromEx.Plug.call(conn, opts)
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Unauthorized")
    |> halt()
  end
end
