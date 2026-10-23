defmodule FluxValeWeb.Plugs.EdgeHostTest do
  @moduledoc false

  # Instance-host dispatch (#203): a rewrite needs BOTH facts — a
  # strict subdomain of the instances' base domain AND the wake-marker
  # header. One alone passes through (the platform's own host never
  # carries the marker; a marked request to another host isn't ours).

  use ExUnit.Case, async: true

  import Plug.Test

  alias FluxValeWeb.Plugs.EdgeHost

  @marker "x-fluxvale-instance"
  @opts EdgeHost.init([])

  defp call(host, path \\ "/some/path", query \\ "a=1", marker \\ "an-instance-id") do
    base = conn(:get, path)
    with_host = %{base | host: host, query_string: query}

    conn =
      if marker do
        Plug.Conn.put_req_header(with_host, @marker, marker)
      else
        with_host
      end

    EdgeHost.call(conn, @opts)
  end

  test "a marked instance-host request rewrites onto the reserved prefix" do
    conn = call("lively-wave-1234.fluxvale.lvh.me")

    assert conn.request_path == "/_fluxvale_edge/some/path"
    assert conn.path_info == ["_fluxvale_edge", "some", "path"]
    assert conn.private[:fluxvale_edge_original] == %{path: "/some/path", query: "a=1"}
    assert conn.private[:fluxvale_edge_host] == "lively-wave-1234.fluxvale.lvh.me"
  end

  test "the instance's root path rewrites cleanly (no empty segments)" do
    conn = call("app-instance.fluxvale.lvh.me", "/")

    assert conn.request_path == "/_fluxvale_edge/"
    assert conn.path_info == ["_fluxvale_edge"]
  end

  # Protocol-relative-looking paths ("//evil.example/x") normalize at
  # the rewrite: kept verbatim they'd confuse glob routing and could
  # render off-site Locations downstream. (Asserted here — Plug.Test's
  # own URI parsing reshapes the path before the router sees it.)
  # The path is injected, not routed: Plug.Test parses "//x" as a
  # protocol-relative URI (host x), so conn(:get, "//evil.example/path")
  # never reaches the plug with that path — a raw HTTP client does.
  test "leading double slashes normalize before the rewrite" do
    base = conn(:get, "/")

    edge =
      base
      |> Map.put(:request_path, "//evil.example/path")
      |> Map.put(:host, "lively-wave-1234.fluxvale.lvh.me")
      |> Plug.Conn.put_req_header(@marker, "an-instance-id")

    result = EdgeHost.call(edge, @opts)

    assert result.request_path == "/_fluxvale_edge/evil.example/path"
    assert result.private[:fluxvale_edge_original].path == "/evil.example/path"
  end

  test "an unmarked subdomain passes through — the platform's own host shape" do
    conn = call("app.fluxvale.lvh.me", "/some/path", "a=1", nil)

    assert conn.request_path == "/some/path"
    refute conn.private[:fluxvale_edge_original]
  end

  test "a marked request to a non-instance host passes through" do
    for host <- ["fluxvale.com", "fluxvale.lvh.me", "localhost", "example.com"] do
      conn = call(host)
      assert conn.request_path == "/some/path"
      refute conn.private[:fluxvale_edge_original]
    end
  end
end
