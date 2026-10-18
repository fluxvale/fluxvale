defmodule FluxValeWeb.Plugs.CaptureIpCountryTest do
  @moduledoc """
  The geo-header capture (#138): only the edge-owned cf-ipcountry is
  trusted (client-settable headers would forge the OSS location
  evidence); absence clears any stale session value.
  """

  use FluxValeWeb.ConnCase, async: true

  alias FluxValeWeb.Plugs.CaptureIpCountry

  # The plug's contract is "after fetch_session" (the :browser pipeline
  # guarantees it); Plug.Test.init_test_session stands in for the plug.
  defp plug_conn(conn), do: Plug.Test.init_test_session(conn, %{})

  test "stores the cf-ipcountry value in the session", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
      |> Plug.Conn.put_req_header("cf-ipcountry", "DE")
      |> CaptureIpCountry.call([])

    assert Plug.Conn.get_session(conn, "ip_country") == "DE"
  end

  test "the value is trimmed and uppercased", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
      |> Plug.Conn.put_req_header("cf-ipcountry", " fr ")
      |> CaptureIpCountry.call([])

    assert Plug.Conn.get_session(conn, "ip_country") == "FR"
  end

  test "a client-settable lookalike header is not trusted", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
      |> Plug.Conn.put_req_header("x-ip-country", "FR")
      |> CaptureIpCountry.call([])

    refute Plug.Conn.get_session(conn, "ip_country")
  end

  test "no geo header clears a stale session value", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
      |> Plug.Test.init_test_session(%{"ip_country" => "DE"})
      |> CaptureIpCountry.call([])

    refute Plug.Conn.get_session(conn, "ip_country")
  end

  test "a blank header value records nothing", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
      |> Plug.Conn.put_req_header("cf-ipcountry", "   ")
      |> CaptureIpCountry.call([])

    refute Plug.Conn.get_session(conn, "ip_country")
  end

  test "init/1 passes opts through" do
    assert CaptureIpCountry.init([]) == []
  end
end
