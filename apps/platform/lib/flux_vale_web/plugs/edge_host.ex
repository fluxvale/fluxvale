defmodule FluxValeWeb.Plugs.EdgeHost do
  @moduledoc """
  Instance-host dispatch (#203, ADR-0036): requests arriving for an
  INSTANCE's hostname — sleeping instances' edge routes hand their
  traffic to this endpoint, original host and all — are rewritten onto
  a reserved prefix before routing, so the wake endpoint sees them no
  matter what path the visitor asked for.

  Why a plug and not the router: an instance serves arbitrary paths,
  and several of them (`/`, `/apps`, `/catalog`, …) collide with real
  platform routes — a trailing catch-all never sees those, and a
  host-glob scope would swallow the platform's own host locally
  (`app.fluxvale.lvh.me` is a subdomain of the instances' base domain;
  prod's `fluxvale.com` vs `fluxvale.app` never overlap, but the stack
  must behave identically everywhere — ADR-0020).

  Edge traffic is identified by TWO facts, not one: a strict subdomain
  of `instances_base_domain`, AND the platform-minted wake-marker
  header — every wake-mode route carries the marker middleware, and
  the platform's own host never does, so no exclusion list is needed
  (host lists drift per env; the marker is ours alone). A forged
  marker on the platform host reaches the same public wake endpoint
  either way — wake is a routing decision, not an auth boundary.
  """

  @behaviour Plug

  alias Plug.Conn
  alias Plug.Router.Utils

  @prefix "/_fluxvale_edge"

  @impl Plug
  def init(_opts) do
    routes = FluxVale.Infrastructure.Operations.EdgeRoutes
    header = String.downcase(routes.instance_header())
    [base_domain: base_domain(), marker_header: header]
  end

  @impl Plug
  def call(%Conn{} = conn, opts) do
    if edge_request?(conn, opts) do
      rewrite_to_edge(conn)
    else
      conn
    end
  end

  defp edge_request?(conn, opts) do
    host = conn.host
    base = opts[:base_domain]
    marker_headers = Conn.get_req_header(conn, opts[:marker_header])
    marked = List.first(marker_headers)

    is_binary(marked) and host != base and String.ends_with?(host, "." <> base)
  end

  defp rewrite_to_edge(conn) do
    original = %{path: conn.request_path, query: conn.query_string}

    conn
    |> Conn.put_private(:fluxvale_edge_original, original)
    |> Conn.put_private(:fluxvale_edge_host, conn.host)
    |> rewrite(@prefix <> conn.request_path)
  end

  # Plug.Conn has no request_path writer (path_info is the routed
  # truth): rebuild both so the router sees the reserved prefix. The
  # prefix itself is exposed read-only for the router and tests.
  defp rewrite(conn, new_path) do
    %{conn | request_path: new_path, path_info: split_path(new_path)}
  end

  defp split_path(path), do: Utils.split(path)

  @doc "The reserved prefix instance-host requests are rewritten onto."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  defp base_domain do
    Application.fetch_env!(:flux_vale, :instances_base_domain)
  end
end
