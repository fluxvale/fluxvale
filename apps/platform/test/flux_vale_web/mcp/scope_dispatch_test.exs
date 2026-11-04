defmodule FluxValeWeb.Mcp.ScopeDispatchTest do
  @moduledoc """
  The scope filter's dispatch half (#361) — defense in depth:

  - Over the transport, a filtered-out tool called directly is
    unresolvable (phantom's per-session allowlist answers before any
    handler runs).
  - At the handler itself, a session built WITHOUT the allowlist (as
    if the filter never ran) still refuses: every handler re-checks
    the token's scopes before touching an Ash action.
  """

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.Mcp

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.TestSupport.ApiPat
  alias FluxValeWeb.MCP.Router

  setup do
    # The dispatcher resolves tools through phantom's :persistent_term
    # cache — register the router like the plug does.
    Phantom.Test.start(router: Router)
    :ok
  end

  describe "a filtered-out tool called over the transport" do
    test "is refused — the session allowlist never resolves it", %{conn: conn} do
      {_user, pat} = ApiPat.member!(["instances:read"])

      conn = call_tool(conn, pat, "get_wallet", %{"organization_id" => Ecto.UUID.generate()})

      assert conn.status == 200

      # The call never reached a handler: the protocol's invalid-params
      # error, not a tool result.
      [%{"error" => error}] = sse_messages(conn)
      assert error["code"] == -32_602
    end

    # The slice-2 write tools ride the same gate: a read-only token's
    # direct write call is unresolvable before any handler runs.
    test "a read-only token's direct write call is unresolvable too", %{conn: conn} do
      {_user, pat} = ApiPat.member!(["instances:read"])

      conn = call_tool(conn, pat, "stop_instance", %{"id" => Ecto.UUID.generate()})

      assert conn.status == 200

      [%{"error" => error}] = sse_messages(conn)
      assert error["code"] == -32_602
    end
  end

  describe "a filtered-out tool called at the handler" do
    test "refuses with the scope reason even when the allowlist is bypassed" do
      {user, raw} = ApiPat.member!(["instances:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result =
        Phantom.Test.call_tool(session, :get_wallet, %{organization_id: Ecto.UUID.generate()})

      # The handler's own reply: tool error with the scope reason
      # (atom-keyed — this path never touches the wire encoder).
      assert %{isError: true, content: [%{text: text}]} = result
      assert text == "this token lacks the wallet:read scope"
    end

    test "a granted tool passes the same check" do
      {user, raw} = ApiPat.member!(["instances:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result = Phantom.Test.call_tool(session, :list_instances, %{})

      refute Map.has_key?(result, :isError)
      assert %{instances: []} = result.structuredContent
    end

    # The three LIST tools' error arm: the handler-level scope refusal
    # (the transport level never reaches the handler for a filtered-out
    # tool; a handler whose action cannot fail in-process still owns
    # this line).
    test "list_instances refuses a token without instances:read" do
      {user, raw} = ApiPat.member!(["wallet:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result = Phantom.Test.call_tool(session, :list_instances, %{})

      assert %{isError: true, content: [%{text: text}]} = result
      assert text == "this token lacks the instances:read scope"
    end

    test "list_backup_runs refuses a token without backups:read" do
      {user, raw} = ApiPat.member!(["wallet:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result =
        Phantom.Test.call_tool(session, :list_backup_runs, %{instance_id: Ecto.UUID.generate()})

      assert %{isError: true, content: [%{text: text}]} = result
      assert text == "this token lacks the backups:read scope"
    end

    test "list_ledger_entries refuses a token without wallet:read" do
      {user, raw} = ApiPat.member!(["instances:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result =
        Phantom.Test.call_tool(session, :list_ledger_entries, %{wallet_id: Ecto.UUID.generate()})

      assert %{isError: true, content: [%{text: text}]} = result
      assert text == "this token lacks the wallet:read scope"
    end

    # The slice-2 writes re-check the WRITE scope at the handler —
    # one per family.
    test "stop_instance refuses a token without instances:write" do
      {user, raw} = ApiPat.member!(["instances:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result = Phantom.Test.call_tool(session, :stop_instance, %{id: Ecto.UUID.generate()})

      assert %{isError: true, content: [%{text: text}]} = result
      assert text == "this token lacks the instances:write scope"
    end

    test "run_backup refuses a token without backups:write" do
      {user, raw} = ApiPat.member!(["backups:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result = Phantom.Test.call_tool(session, :run_backup, %{id: Ecto.UUID.generate()})

      assert %{isError: true, content: [%{text: text}]} = result
      assert text == "this token lacks the backups:write scope"
    end

    test "create_gateway refuses a token without gateways:write" do
      {user, raw} = ApiPat.member!(["gateways:read"])

      session =
        Phantom.Test.build_session(Router,
          assigns: %{user: user, pat: pat_row!(raw)},
          protocol_version: "2026-07-28"
        )

      result =
        Phantom.Test.call_tool(session, :create_gateway, %{
          tailnet_domain: "example.ts.net",
          auth_key: "tskey-test"
        })

      assert %{isError: true, content: [%{text: text}]} = result
      assert text == "this token lacks the gateways:write scope"
    end
  end

  # connect/2 assigns the PAT ROW (the scope source); the handler-level
  # session mirrors that — resolved the way Authenticate resolves it.
  defp pat_row!(raw) do
    hash = PersonalAccessToken.token_hash(raw)
    {:ok, pat} = PersonalAccessToken.get_by_token_hash(hash, authorize?: false)
    pat
  end
end
