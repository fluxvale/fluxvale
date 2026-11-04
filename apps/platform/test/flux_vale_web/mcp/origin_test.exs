defmodule FluxValeWeb.Mcp.OriginTest do
  @moduledoc """
  The origin-validation wiring (#361): prod builds run phantom's
  validate_origin against the application-env allowlist (config.exs's
  canonical default; runtime override per deployment — Phantom.Plug
  re-reads the router module's app env on every request). Dev/test
  builds skip the check entirely — tools and tests must not need
  origin gymnastics.
  """

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.Mcp

  alias FluxVale.TestSupport.ApiPat
  alias FluxValeWeb.MCP.Origins

  @canonical_origin "https://fluxvale.com"

  describe "the application-env allowlist" do
    test "defaults to the canonical prod origin" do
      assert Application.get_env(:flux_vale, :mcp_origins) == [@canonical_origin]
    end

    test "the gate is membership in that list" do
      refute Origins.allowed?("https://evil.example")
      assert Origins.allowed?(@canonical_origin)
    end
  end

  describe "prod-mode wiring (Phantom.Plug with validate_origin: true)" do
    # A protocol-valid tools/list POST, driven straight into
    # Phantom.Plug — the shape prod's pipeline hands it after the
    # parsers. No :origins opt: phantom's default is a localhost list,
    # so whatever answers here came from the application-env merge.
    defp prod_post(origin) do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/list",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })

      base_headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "tools/list"}
      ]

      headers =
        if origin do
          base_headers ++ [{"origin", origin}]
        else
          base_headers
        end

      base = build_conn(:post, "/mcp", body)

      conn =
        Enum.reduce(headers, base, fn {name, value}, acc ->
          put_req_header(acc, name, value)
        end)

      parsed =
        Plug.Parsers.call(
          conn,
          Plug.Parsers.init(
            parsers: [{:json, length: 1_000_000}],
            pass: ["application/json"],
            json_decoder: Jason
          )
        )

      opts =
        Phantom.Plug.init(
          router: FluxValeWeb.MCP.Router,
          validate_origin: true,
          # The forward opts' own shape: the app-env MFA (this suite
          # pins it above — membership in :mcp_origins).
          origins: {FluxValeWeb.MCP.Origins, :allowed?, []}
        )

      Phantom.Plug.call(parsed, opts)
    end

    test "a foreign origin is rejected before any auth is consulted" do
      conn = prod_post("https://evil.example")

      assert conn.status == 403
      assert conn.resp_body =~ "Origin not allowed"
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []
    end

    test "the canonical origin passes through to the auth layer" do
      conn = prod_post(@canonical_origin)

      # No token rode along: the origin gate passed, connect/2's
      # challenge is what answers.
      assert conn.status == 401
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") != []
    end

    test "no origin (a plain MCP client) passes through to the auth layer" do
      conn = prod_post(nil)

      assert conn.status == 401
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") != []
    end
  end

  describe "dev/test wiring (validate_origin: false)" do
    test "a foreign origin through the real endpoint reaches the auth layer", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example")
        |> list_tools(nil)

      # validate_origin is off in test builds, so the foreign origin is
      # NOT the thing that answers: the missing token is.
      assert conn.status == 401
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") != []
      refute conn.resp_body =~ "Origin not allowed"
    end

    test "a valid token's call succeeds from any origin", %{conn: conn} do
      {_user, pat} = ApiPat.member!()

      conn =
        conn
        |> put_req_header("origin", "https://foreign.example")
        |> list_tools(pat)

      assert conn.status == 200
    end
  end
end
