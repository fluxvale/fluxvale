defmodule FluxValeWeb.Mcp.ScopeListingTest do
  @moduledoc """
  The scope filter's listing half (#361): a token's tools/list offers
  only what its scopes cover. The full-scope token sees the whole
  catalog — the 9 reads plus the 13 writes of slice 2 (the task
  header's "12" misses `destroy_instance`, which the spec's own tool
  list, confirm design, and test plan all name). Narrower tokens see
  their family plus `whoami` — and a token without the write scope
  never sees a write tool (a `write` grant implies its family's
  reads).
  """

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.Mcp

  alias FluxVale.TestSupport.ApiPat

  describe "tools/list with a full-scope token" do
    test "sees the whole catalog — the nine reads plus the thirteen writes", %{conn: conn} do
      {_user, pat} = ApiPat.member!()

      names = tool_names(conn, pat)

      assert MapSet.new(names) ==
               MapSet.new([
                 # the slice-1 reads
                 "whoami",
                 "list_instances",
                 "get_instance",
                 "list_apps",
                 "get_backup_settings",
                 "list_backup_runs",
                 "get_gateway",
                 "get_wallet",
                 "list_ledger_entries",
                 # the slice-2 writes
                 "deploy_instance",
                 "stop_instance",
                 "start_instance",
                 "set_instance_always_on",
                 "set_instance_exposure",
                 "destroy_instance",
                 "configure_backups",
                 "run_backup",
                 "restore_backup",
                 "attach_instance",
                 "detach_instance",
                 "create_gateway",
                 "resume_gateway"
               ])
    end
  end

  describe "tools/list with an instances:read-only token" do
    test "sees only whoami and the instances family — no write tool", %{conn: conn} do
      {_user, pat} = ApiPat.member!(["instances:read"])

      names = tool_names(conn, pat)

      assert MapSet.new(names) == MapSet.new(["whoami", "list_instances", "get_instance"])
      refute "get_wallet" in names
      refute "list_ledger_entries" in names
      refute "list_backup_runs" in names
      refute "get_gateway" in names
      refute "list_apps" in names

      # The slice-2 writes are structurally absent.
      refute "deploy_instance" in names
      refute "stop_instance" in names
      refute "start_instance" in names
      refute "set_instance_always_on" in names
      refute "set_instance_exposure" in names
      refute "destroy_instance" in names
    end

    test "a wallet:read-only token sees only whoami and the wallet family", %{conn: conn} do
      {_user, pat} = ApiPat.member!(["wallet:read"])

      names = tool_names(conn, pat)

      assert MapSet.new(names) == MapSet.new(["whoami", "get_wallet", "list_ledger_entries"])
    end

    test "an instances:write-only token sees the family's reads AND its six writes", %{
      conn: conn
    } do
      # write implies read (Scopes.grants?/2) — the family's whole
      # surface, and nothing from any other family.
      {_user, pat} = ApiPat.member!(["instances:write"])

      names = tool_names(conn, pat)

      assert MapSet.new(names) ==
               MapSet.new([
                 "whoami",
                 "list_instances",
                 "get_instance",
                 "deploy_instance",
                 "stop_instance",
                 "start_instance",
                 "set_instance_always_on",
                 "set_instance_exposure",
                 "destroy_instance"
               ])

      refute "run_backup" in names
      refute "restore_backup" in names
      refute "create_gateway" in names
      refute "list_ledger_entries" in names
    end

    test "a backups:write-only token sees the backups family's reads and writes", %{conn: conn} do
      {_user, pat} = ApiPat.member!(["backups:write"])

      names = tool_names(conn, pat)

      assert MapSet.new(names) ==
               MapSet.new([
                 "whoami",
                 "get_backup_settings",
                 "list_backup_runs",
                 "configure_backups",
                 "run_backup",
                 "restore_backup"
               ])

      refute "stop_instance" in names
      refute "attach_instance" in names
    end
  end

  defp tool_names(conn, pat) do
    conn = list_tools(conn, pat)
    assert conn.status == 200

    conn
    |> result()
    |> Map.fetch!("tools")
    |> Enum.map(&Map.fetch!(&1, "name"))
    |> Enum.sort()
  end
end
