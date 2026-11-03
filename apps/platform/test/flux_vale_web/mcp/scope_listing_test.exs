defmodule FluxValeWeb.Mcp.ScopeListingTest do
  @moduledoc """
  The scope filter's listing half (#361): a token's tools/list offers
  only what its scopes cover. The full-scope token sees all nine
  slice-1 tools; an instances:read-only token sees exactly the
  instances family plus the scopeless whoami — write tools (slice 2's)
  are structurally absent from a read-only token's listing.
  """

  use FluxValeWeb.ConnCase, async: true

  import FluxVale.TestSupport.Mcp

  alias FluxVale.TestSupport.ApiPat

  describe "tools/list with a full-scope token" do
    test "sees all nine read tools", %{conn: conn} do
      {_user, pat} = ApiPat.member!()

      names = tool_names(conn, pat)

      assert MapSet.new(names) ==
               MapSet.new([
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
    end
  end

  describe "tools/list with an instances:read-only token" do
    test "sees only whoami and the instances family", %{conn: conn} do
      {_user, pat} = ApiPat.member!(["instances:read"])

      names = tool_names(conn, pat)

      assert MapSet.new(names) == MapSet.new(["whoami", "list_instances", "get_instance"])
      refute "get_wallet" in names
      refute "list_ledger_entries" in names
      refute "list_backup_runs" in names
      refute "get_gateway" in names
      refute "list_apps" in names
    end

    test "a wallet:read-only token sees only whoami and the wallet family", %{conn: conn} do
      {_user, pat} = ApiPat.member!(["wallet:read"])

      names = tool_names(conn, pat)

      assert MapSet.new(names) == MapSet.new(["whoami", "get_wallet", "list_ledger_entries"])
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
