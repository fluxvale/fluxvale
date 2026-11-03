defmodule FluxValeWeb.Mcp.TransportTest do
  @moduledoc """
  The /mcp transport's auth contract (#361, ADR-0019 §3): the
  protocol-correct 401 challenge for no/invalid PATs — NOT the
  JSON:API error document — and a full-scope PAT's tools/list.

  Dev/test builds carry `validate_origin: false`, so no Origin header
  is needed here (the prod wiring is its own suite).
  """

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.Mcp

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.AccessRules
  alias FluxVale.TestSupport.ApiPat
  alias FluxValeWeb.MCP.Router

  @tool_names MapSet.new([
                "whoami",
                "list_instances",
                "get_instance",
                "list_apps",
                "get_backup_settings",
                "list_backup_runs",
                "get_gateway",
                "get_wallet",
                "list_ledger_entries"
              ])

  describe "POST /mcp without a token" do
    test "answers the protocol 401 with a Bearer challenge", %{conn: conn} do
      conn = list_tools(conn, nil)

      assert conn.status == 401
      assert [challenge] = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert challenge =~ "Bearer"

      # The MCP challenge shape — a JSON-RPC error, never the JSON:API
      # document the /api/v1 boundary renders.
      body = json_response(conn, 401)
      assert %{"error" => %{"message" => "Unauthorized"}} = body
      refute Map.has_key?(body, "errors")
    end

    test "answers the protocol 401 for a forged fvpat bearer", %{conn: conn} do
      conn = list_tools(conn, nil, authorization: {:bearer, "fvpat_" <> "bogus"})

      challenge = Plug.Conn.get_resp_header(conn, "www-authenticate")
      assert conn.status == 401
      assert challenge != []
      assert %{"error" => _error} = json_response(conn, 401)
    end

    test "answers the protocol 401 for a non-PAT bearer", %{conn: conn} do
      conn = list_tools(conn, nil, authorization: {:bearer, "not-a-token"})

      assert conn.status == 401
    end
  end

  describe "POST /mcp with a full-scope PAT" do
    test "lists the slice's nine read tools over SSE", %{conn: conn} do
      {_user, pat} = ApiPat.member!()

      conn = list_tools(conn, pat)

      assert conn.status == 200

      assert Plug.Conn.get_resp_header(conn, "content-type") == [
               "text/event-stream; charset=utf-8"
             ]

      tools = result(conn)["tools"]
      names = Enum.map(tools, &Map.fetch!(&1, "name"))
      assert MapSet.new(names) == @tool_names

      # The agent-facing annotations ride the listing: every slice-1
      # tool is a read.
      assert Enum.all?(tools, fn tool -> tool["annotations"]["readOnlyHint"] == true end)

      # Descriptions are agent-facing prose, never nil.
      assert Enum.all?(tools, fn tool -> is_binary(tool["description"]) end)
    end

    test "the server advertises the app's live OTP version" do
      # phantom's compile-time otp_app resolution comes up empty for the
      # app being compiled; server_info (consumed by initialize) reads
      # the live spec instead — pinned here, initialize itself is a
      # legacy-mode flow the dep owns.
      session = struct(Phantom.Session, id: "probe")
      {:ok, info} = Router.server_info(session)

      assert info == %{
               name: "FluxVale",
               version: to_string(Application.spec(:flux_vale, :vsn))
             }
    end
  end

  describe "POST /mcp with an AccessRule-denied account" do
    # The rule allows @fluxvale.com only — the outsider's domain is
    # denied, the token row survives Authenticate (api_pat stays
    # assigned), and connect/2 answers 403, not 401.
    setup do
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
      :ok
    end

    test "a rule landing mid-request refuses connect/2 with the same 403" do
      # The window between Authenticate's check and connect's re-check
      # cannot be hit from a request; the unit seam pins the arm.
      {_user, raw} = ApiPat.member!()
      hash = PersonalAccessToken.token_hash(raw)
      {:ok, pat} = PersonalAccessToken.get_by_token_hash(hash, authorize?: false)
      session = struct(Phantom.Session, id: "probe")

      Mimic.copy(AccessRules)
      stub(AccessRules, :ensure_allowed_user, fn _user -> {:error, :not_allowed} end)

      conn = %Plug.Conn{
        assigns: %{current_user: nil, api_pat: pat},
        private: %{phantom: %{modern: true}}
      }

      assert {:forbidden, "this account is not allowed to use FluxVale"} =
               Router.connect(session, conn)
    end

    test "answers the protocol 403 — the account is refused, not the credential", %{conn: conn} do
      outsider =
        User.create!(
          "mcp-outsider-#{System.unique_integer()}@example.com",
          %{},
          authorize?: false
        )

      {:ok, %{token: token}} =
        FluxVale.Identity.mint_pat(outsider, %{
          user_id: outsider.id,
          name: "mcp",
          scopes: ["instances:read"]
        })

      conn = list_tools(conn, token)

      assert conn.status == 403
      assert conn.resp_body =~ "not allowed"
      # No challenge: the token was live; the account behind it is not.
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []
    end
  end

  describe "POST /mcp from a legacy protocol client" do
    test "a valid PAT and a legacy protocol version answer the stateless-only refusal", %{
      conn: conn
    } do
      {_user, pat} = ApiPat.member!()

      conn = post(conn, pat, "tools/list", %{}, legacy: true)

      # After auth (the token is live): the constraint, not a challenge.
      assert conn.status == 403
      assert conn.resp_body =~ "stateless protocol rev 2026-07-28"
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []
    end

    test "no protocol header at all is the legacy shape and refuses the same way", %{conn: conn} do
      {_user, pat} = ApiPat.member!()

      conn = post(conn, pat, "tools/list", %{}, legacy: true, protocol_version: :none)

      assert conn.status == 403
      assert conn.resp_body =~ "stateless protocol rev 2026-07-28"
    end
  end
end
