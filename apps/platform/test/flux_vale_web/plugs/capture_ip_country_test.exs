defmodule FluxValeWeb.Plugs.CaptureIpCountryTest do
  @moduledoc """
  The geo-header capture (#138): cf-ipcountry preferred, x-ip-country
  as fallback, absence tolerated — the session carries what the edge
  reported.
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

  test "falls back to x-ip-country when the edge header is absent", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
      |> Plug.Conn.put_req_header("x-ip-country", "fr")
      |> CaptureIpCountry.call([])

    assert Plug.Conn.get_session(conn, "ip_country") == "FR"
  end

  test "cf-ipcountry wins when both headers ride the request", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
      |> Plug.Conn.put_req_header("cf-ipcountry", "DE")
      |> Plug.Conn.put_req_header("x-ip-country", "FR")
      |> CaptureIpCountry.call([])

    assert Plug.Conn.get_session(conn, "ip_country") == "DE"
  end

  test "no geo header records nothing", %{conn: conn} do
    conn =
      conn
      |> plug_conn()
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
