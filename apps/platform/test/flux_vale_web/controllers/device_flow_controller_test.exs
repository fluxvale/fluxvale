defmodule FluxValeWeb.Api.DeviceFlowControllerTest do
  @moduledoc false

  # #362 T3: the RFC 8628 wire contract, end to end over plain JSON —
  # the mint shape and error shapes (§3.1/§3.2), the poll matrix
  # (§3.5: authorization_pending/slow_down/access_denied/expired_token
  # + the one-time grant), and the wrong-client/bad-scope refusals.
  # The routes are NOT the ash_json_api router (unauthenticated by
  # design — the scope gate does not apply; asserted at the bottom).

  # Not async: one test opens the global Logger level to capture the
  # info lines (the codes/tokens-never-logged proof) — a node-global;
  # the runtime_config_test posture for VM-global state.
  use FluxValeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias FluxVale.Api.Scopes
  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.SessionHelpers

  @client "fluxvale-cli"
  @grant "urn:ietf:params:oauth:grant-type:device_code"
  @verification_uri "https://fluxvale.com/settings/access/device"

  describe "POST /api/v1/device/code" do
    test "mints: the RFC 8628 §3.1 payload, verbatim keys", %{conn: conn} do
      {result, body} =
        post_code(conn, %{client_id: @client, scopes: ["instances:read", "wallet:read"]})

      assert result == 200

      keys = Map.keys(body)

      assert MapSet.new(keys) ==
               MapSet.new(~w(device_code user_code verification_uri expires_in interval))

      assert body["device_code"] =~ ~r/^[A-Za-z0-9_-]{43}$/
      assert body["user_code"] =~ ~r/^[A-HJ-KMNP-Z2-9]{4}-[A-HJ-KMNP-Z2-9]{4}$/

      # The approval panel's URL on the canonical origin (the CLI's
      # human follows this, so it must be the prod URL regardless of
      # the serving host — the SEO config's stance).
      assert body["verification_uri"] == @verification_uri

      assert body["expires_in"] == DeviceCode.ttl_seconds()
      assert body["interval"] == 5

      # A pending row actually landed.
      assert {:ok, _row} =
               DeviceCode.get_by_device_code(body["device_code"], authorize?: false)
    end

    test "an unknown client answers 400 invalid_client (§5.2 shape)", %{conn: conn} do
      {result, body} = post_code(conn, %{client_id: "someone-elses", scopes: []})

      assert result == 400
      assert body["error"] == "invalid_client"
      assert is_binary(body["error_description"])
    end

    test "a missing client answers 400 invalid_client", %{conn: conn} do
      {result, body} = post_code(conn, %{"scopes" => []})

      assert result == 400
      assert body["error"] == "invalid_client"
    end

    test "an off-catalog scope answers 400 invalid_scope", %{conn: conn} do
      {result, body} = post_code(conn, %{client_id: @client, scopes: ["wallet:write"]})

      assert result == 400
      assert body["error"] == "invalid_scope"
      assert body["error_description"] =~ "wallet:write"
    end

    test "a duplicate scope answers 400 invalid_scope", %{conn: conn} do
      {result, body} =
        post_code(conn, %{client_id: @client, scopes: ["instances:read", "instances:read"]})

      assert result == 400
      assert body["error"] == "invalid_scope"
    end

    test "a non-array scopes body answers 400 invalid_scope (not a 500)", %{conn: conn} do
      {result, body} = post_code(conn, %{client_id: @client, scopes: "instances:read"})

      assert result == 400
      assert body["error"] == "invalid_scope"
    end

    test "nothing is created on a refusal", %{conn: conn} do
      post_code(conn, %{client_id: "someone-elses", scopes: []})

      assert [] = DeviceCode.pending!(actor: nil, authorize?: false)
    end
  end

  describe "POST /api/v1/device/token — the poll matrix" do
    test "pending: 400 authorization_pending", %{conn: conn} do
      {:ok, row} = mint()

      {result, body} = poll(conn, row.device_code)

      assert result == 400
      assert body["error"] == "authorization_pending"
    end

    test "pending + too soon: 400 slow_down", %{conn: conn} do
      {:ok, row} = mint()

      assert {400, %{"error" => "authorization_pending"}} = poll(conn, row.device_code)

      # Second poll inside the interval — no sleep: two HTTP calls
      # inside one test are always inside 5 seconds.
      {result, body} = poll(conn, row.device_code)

      assert result == 400
      assert body["error"] == "slow_down"
    end

    test "denied: 400 access_denied", %{conn: conn} do
      approver = User.create!("wire-denied@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint()

      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _denied} = DeviceCode.deny(pending_row, actor: approver)

      {result, body} = poll(conn, minted.device_code)

      assert result == 400
      assert body["error"] == "access_denied"
    end

    test "expired: 400 expired_token", %{conn: conn} do
      # Seed-only state: already past expiry (no action produces it).
      Ash.Seed.seed!(DeviceCode, %{
        id: Ash.UUIDv7.generate(),
        device_code: "wire-expired-code-0000000000000000000000000000000",
        user_code: "WIRE-EXPR",
        client_id: @client,
        scopes: [],
        status: :pending,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second),
        poll_count: 0
      })

      {result, body} = poll(conn, "wire-expired-code-0000000000000000000000000000000")

      assert result == 400
      assert body["error"] == "expired_token"
    end

    test "unknown device_code: 400 expired_token (no existence oracle)", %{conn: conn} do
      {result, body} = poll(conn, "never-minted-code-000000000000000000000000000")

      assert result == 400
      assert body["error"] == "expired_token"
    end

    test "success: 200 with the one-time grant; the poll again is 400 expired_token", %{
      conn: conn
    } do
      approver = User.create!("wire-approver@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint(scopes: ["instances:read", "backups:write"])

      # The panel's click, simulated (the :approve action with the
      # actor — the same call the LiveView makes).
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, actor: approver)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/device/token", %{
          "client_id" => @client,
          "device_code" => minted.device_code,
          "grant_type" => @grant
        })

      body = json_response(conn, 200)

      assert body["access_token"] =~ ~r/^fvpat_[A-Za-z0-9_-]{43}$/
      assert body["token_type"] == "Bearer"

      # The granted scopes, space-joined (RFC 8628 §3.4 / OAuth §5.1).
      assert body["scope"] == "instances:read backups:write"

      # The PAT's remaining seconds (~1 year).
      assert body["expires_in"] > 365 * 24 * 60 * 60 - 120

      # RFC 6749 §5.1: token responses are no-store.
      assert Enum.member?(conn.resp_headers, {"cache-control", "no-store"})
      assert Enum.member?(conn.resp_headers, {"pragma", "no-cache"})

      # The token crosses the wire THIS once — the immediate re-poll
      # (a fresh conn: the first already sent) answers expired_token
      # (the row is consumed), and the minted PAT authenticates the
      # machine API for real.
      assert {400, %{"error" => "expired_token"}} = poll(build_conn(), minted.device_code)

      me =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> body["access_token"])
        |> get("/api/v1/me")

      assert %{"data" => %{"id" => id}} = json_response(me, 200)
      assert id == approver.id
    end

    test "the minted PAT carries the provenance metadata", %{conn: conn} do
      approver = User.create!("wire-provenance@fluxvale.com", %{}, authorize?: false)
      {:ok, minted} = mint()

      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, actor: approver)

      {_result, body} = poll(conn, minted.device_code)
      token_hash = PersonalAccessToken.token_hash(body["access_token"])

      assert {:ok, pat} = PersonalAccessToken.get_by_token_hash(token_hash, authorize?: false)

      assert pat.metadata == %{
               "client_id" => @client,
               "grant_type" => "device_flow",
               "scopes" => [],
               "minted_via" => "device"
             }
    end

    test "wrong client on the poll: 400 invalid_client", %{conn: conn} do
      {:ok, row} = mint()

      {result, body} =
        poll(conn, row.device_code, %{"client_id" => "someone-elses"})

      assert result == 400
      assert body["error"] == "invalid_client"
    end

    test "a wrong grant_type answers 400 unsupported_grant_type", %{conn: conn} do
      {:ok, row} = mint()

      {result, body} =
        poll(conn, row.device_code, %{"grant_type" => "authorization_code"})

      assert result == 400
      assert body["error"] == "unsupported_grant_type"
    end
  end

  describe "the wire's posture" do
    test "the endpoints are outside the scope table (unauthenticated by design —
    the gate does not apply to them)" do
      # The boundary plug denies-by-default on unmapped paths for
      # TOKEN callers; the device routes never reach it (mounted
      # outside the /api/v1 forward). The table's silence is the
      # assertion: these are not token-API routes.
      assert Scopes.required_scope("POST", ["device", "code"]) == :error
      assert Scopes.required_scope("POST", ["device", "token"]) == :error
    end

    test "poll logs name outcomes, never codes or tokens", %{conn: conn} do
      {:ok, row} = mint()

      # The suite runs at :warning — open the level for the capture
      # and restore immediately (this module runs exclusively, so no
      # async capture can be mid-window when the level closes).
      previous = Logger.level()
      Logger.configure(level: :info)

      {_result, log} =
        with_log(fn -> poll(conn, row.device_code) end)

      Logger.configure(level: previous)

      refute log =~ row.device_code
      refute log =~ row.user_code
      assert log =~ "authorization_pending"
    end
  end

  describe "GET /settings/access/device — the verification_uri landing" do
    test "a signed-in visitor redirects to the access panel at the section", %{conn: conn} do
      user = User.create!("entry-signed-in@fluxvale.com", %{}, authorize?: false)
      signed_in = SessionHelpers.sign_in(conn, user)

      conn = get(signed_in, "/settings/access/device")

      assert redirected_to(conn) == "/settings/access#device-sign-ins"
    end

    test "an anonymous visitor redirects to sign-in", %{conn: conn} do
      conn = get(conn, "/settings/access/device")

      assert redirected_to(conn) == "/sign-in"
    end
  end

  defp post_code(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/device/code", params)
    |> json_response_with_status()
  end

  defp poll(conn, device_code, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "client_id" => @client,
          "device_code" => device_code,
          "grant_type" => @grant
        },
        overrides
      )

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/device/token", params)
    |> json_response_with_status()
  end

  # status + decoded body in one hop (Phoenix's json_response raises
  # on non-JSON content types — these endpoints always answer JSON).
  defp json_response_with_status(conn) do
    {conn.status, json_response(conn, conn.status)}
  end

  defp mint(overrides \\ []) do
    scopes = Keyword.get(overrides, :scopes, [])

    assert {:ok, row} = Identity.mint_device_code(%{client_id: @client, scopes: scopes})
    {:ok, row}
  end
end
