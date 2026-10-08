defmodule FluxValeWeb.Plugs.MetricsEndpointTest do
  @moduledoc """
  The /metrics gate (#98): bearer-token when :metrics_token is set, open
  otherwise; exact path only.
  """

  # async: false — the token tests mutate the global :metrics_token app
  # env (capture-and-restore via on_exit).
  use FluxValeWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:flux_vale, :metrics_token)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:flux_vale, :metrics_token)
        set -> Application.put_env(:flux_vale, :metrics_token, set)
      end
    end)

    :ok
  end

  test "open when no token is configured (dev/test shape)", %{conn: conn} do
    Application.delete_env(:flux_vale, :metrics_token)

    # PromEx is down in test — the gate passing through answers 503
    assert get(conn, "/metrics").status == 503
  end

  test "401 without the bearer when a token is configured", %{conn: conn} do
    Application.put_env(:flux_vale, :metrics_token, "s3cr3t")

    assert get(conn, "/metrics").status == 401

    wrong = put_req_header(conn, "authorization", "Bearer wrong")

    assert get(wrong, "/metrics").status == 401
  end

  test "past the bearer, the scrape endpoint answers", %{conn: conn} do
    Application.put_env(:flux_vale, :metrics_token, "s3cr3t")

    conn =
      conn
      |> put_req_header("authorization", "Bearer s3cr3t")
      |> get("/metrics")

    # PromEx is down in test — 503 is the gated-through answer
    assert conn.status == 503
  end

  test "paths deeper than /metrics 404 instead of a 500", %{conn: conn} do
    assert get(conn, "/metrics/anything").status == 404
  end
end
