defmodule FluxVale.PromExTest do
  @moduledoc """
  Plugin presence (ADR-0012: Phoenix/Ecto/Oban/BEAM) and the scrape
  contract: 503 while the tree is down (dev/test), Prometheus text when
  it runs.
  """

  # async: false — the enabled test starts the module-named PromEx tree,
  # which is VM-global (one instance of the named processes).
  use FluxValeWeb.ConnCase, async: false

  @plugins FluxVale.PromEx.plugins()

  test "plugins cover Phoenix, Ecto, Oban, and the BEAM" do
    assert {PromEx.Plugins.Phoenix, opts} = Enum.at(@plugins, 0)
    assert opts[:endpoint] == FluxValeWeb.Endpoint
    assert opts[:router] == FluxValeWeb.Router

    assert {PromEx.Plugins.Ecto, opts} = Enum.at(@plugins, 1)
    assert opts[:repos] == [FluxVale.Repo]

    assert {PromEx.Plugins.Oban, opts} = Enum.at(@plugins, 2)
    assert opts[:oban_supervisors] == [Oban]

    assert {PromEx.Plugins.Beam, _opts} = Enum.at(@plugins, 3)
  end

  test "GET /metrics answers 503 while the PromEx tree is down", %{conn: conn} do
    # PromEx is not started in test (test.exs pins it off) — the default
    # shape every scrape sees outside prod-shaped runs.
    conn = get(conn, "/metrics")

    assert conn.status == 503
  end

  test "GET /metrics serves Prometheus text once the tree runs", %{conn: conn} do
    start_supervised!(FluxVale.PromEx)

    conn = get(conn, "/metrics")

    assert conn.status == 200
    assert String.contains?(conn.resp_body, "# TYPE")
  end
end
