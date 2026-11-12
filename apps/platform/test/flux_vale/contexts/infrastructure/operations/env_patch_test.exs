defmodule FluxVale.Infrastructure.Operations.EnvPatchTest do
  @moduledoc false

  # #731 T1 (ADR-0052): the pure merge verb's rules — validation,
  # deployer-owned refusal/skip (exact OIDC/URL keys, folded backing
  # URLs), first-run contract refusals (fixed and forbidden), overlap,
  # merge and the audit-name diff.

  use ExUnit.Case, async: true

  alias FluxVale.Infrastructure.Operations.EnvPatch

  defp version(attrs \\ %{}) do
    Map.merge(
      %{
        oidc_wiring: nil,
        instance_url_env: nil,
        host_allowlist_env: "ALLOWED_HOSTS",
        first_run: nil
      },
      Map.new(attrs)
    )
  end

  defp instance(attrs \\ %{}) do
    Map.merge(%{backing_services: []}, Map.new(attrs))
  end

  defp wiring(attrs \\ %{}) do
    Map.merge(
      %{
        issuer_env: "SSO_AUTHORITY",
        client_id_env: "SSO_CLIENT_ID",
        client_secret_env: "SSO_CLIENT_SECRET",
        enabled_env: "SSO_ENABLED"
      },
      Map.new(attrs)
    )
  end

  defp contract(attrs) do
    Map.merge(%{env: %{}, forbidden_env: []}, Map.new(attrs))
  end

  defp owned(exact \\ [], folded \\ []) do
    folded = Enum.map(folded, &String.downcase/1)

    %{
      exact: MapSet.new(exact),
      folded: MapSet.new(folded)
    }
  end

  describe "plan/6" do
    test "merges set over the row and drops removed keys, diffing the names" do
      current = %{"KEEP" => "1", "CHANGE" => "old", "DROP" => "x"}

      assert {:ok, plan} =
               EnvPatch.plan(
                 current,
                 %{"NEW" => "2", "CHANGE" => "new"},
                 ["DROP", "MISSING"],
                 owned(),
                 [],
                 []
               )

      assert plan.merged == %{"KEEP" => "1", "CHANGE" => "new", "NEW" => "2"}
      assert plan.set == %{"NEW" => "2", "CHANGE" => "new"}
      assert plan.remove == ["DROP", "MISSING"]
      assert plan.skipped == []
      assert plan.composed == []
      assert plan.added == ["NEW"]
      assert plan.changed == ["CHANGE"]
      assert plan.removed == ["DROP"]
    end

    test "an unchanged value is neither added nor changed" do
      assert {:ok, plan} =
               EnvPatch.plan(%{"SAME" => "v"}, %{"SAME" => "v"}, [], owned(), [], [])

      assert plan.added == []
      assert plan.changed == []
      assert plan.merged == %{"SAME" => "v"}
    end

    test "nil set and remove are the wire's absent — a no-op plan" do
      assert {:ok, plan} = EnvPatch.plan(%{"KEEP" => "1"}, nil, nil, owned(), [], [])
      assert plan.set == %{}
      assert plan.remove == []
      assert plan.merged == %{"KEEP" => "1"}
    end

    test "duplicate remove entries are one removal" do
      assert {:ok, plan} =
               EnvPatch.plan(%{"DROP" => "x"}, %{}, ["DROP", "DROP"], owned(), [], [])

      assert plan.remove == ["DROP"]
      assert plan.merged == %{}
    end

    test "a missing remove key is a no-op, not a failure" do
      assert {:ok, plan} = EnvPatch.plan(%{"KEEP" => "1"}, %{}, ["GONE"], owned(), [], [])
      assert plan.removed == []
      assert plan.merged == %{"KEEP" => "1"}
    end

    test "set/remove overlap refuses with the shared names" do
      assert {:error, {:overlap, ["BOTH"]}} =
               EnvPatch.plan(%{}, %{"BOTH" => "v"}, ["BOTH"], owned(), [], [])
    end

    test "set keys must be POSIX-shaped" do
      assert {:error, {:invalid_name, ["1NOPE", "BAD-KEY"]}} =
               EnvPatch.plan(%{}, %{"BAD-KEY" => "v", "1NOPE" => "v"}, [], owned(), [], [])
    end

    test "remove keys need only be strings — a non-POSIX stored key still drops" do
      assert {:ok, plan} =
               EnvPatch.plan(
                 %{"BAD-KEY" => "v", "KEEP" => "1"},
                 %{},
                 ["BAD-KEY"],
                 owned(),
                 [],
                 []
               )

      assert plan.remove == ["BAD-KEY"]
      assert plan.removed == ["BAD-KEY"]
      assert plan.merged == %{"KEEP" => "1"}
    end

    test "remove entries that are not strings refuse" do
      assert {:error, {:invalid_remove, [1]}} =
               EnvPatch.plan(%{}, %{}, [1], owned(), [], [])
    end

    test "set values must be strings" do
      assert {:error, {:invalid_value, ["NUMBER"]}} =
               EnvPatch.plan(%{}, %{"NUMBER" => 1}, [], owned(), [], [])
    end

    test "set must be a map and remove a list" do
      assert {:error, {:invalid_set, "x"}} = EnvPatch.plan(%{}, "x", [], owned(), [], [])
      assert {:error, {:invalid_remove, "x"}} = EnvPatch.plan(%{}, %{}, "x", owned(), [], [])
    end

    test "an exact owned key in set refuses, naming it" do
      assert {:error, {:owned, ["ROOT_URL"]}} =
               EnvPatch.plan(
                 %{},
                 %{"ROOT_URL" => "https://evil"},
                 [],
                 owned(["ROOT_URL"]),
                 [],
                 []
               )
    end

    test "an owned key in remove is skipped — the platform keeps it" do
      assert {:ok, plan} =
               EnvPatch.plan(
                 %{"ROOT_URL" => "https://platform", "KEEP" => "1"},
                 %{"NEW" => "2"},
                 ["ROOT_URL"],
                 owned(["ROOT_URL"]),
                 [],
                 []
               )

      assert plan.skipped == ["ROOT_URL"]
      assert plan.remove == []
      assert plan.removed == []
      assert plan.merged == %{"ROOT_URL" => "https://platform", "KEEP" => "1", "NEW" => "2"}
    end

    test "host_allowlist_env is user-writable — not in either owned set" do
      owned = EnvPatch.owned_keys(instance(), version(), false)
      refute MapSet.member?(owned.exact, "ALLOWED_HOSTS")
      refute MapSet.member?(owned.folded, "allowed_hosts")
    end

    test "a first-run contract env key refuses both a set and a remove" do
      first_run = contract(env: %{"CONTRACT_KEY" => "true"})
      fixed = EnvPatch.fixed_keys(first_run)

      assert {:error, {:fixed, ["CONTRACT_KEY"]}} =
               EnvPatch.plan(%{}, %{"CONTRACT_KEY" => "false"}, [], owned(), fixed, [])

      assert {:error, {:fixed, ["CONTRACT_KEY"]}} =
               EnvPatch.plan(
                 %{"CONTRACT_KEY" => "true", "KEEP" => "1"},
                 %{},
                 ["CONTRACT_KEY"],
                 owned(),
                 fixed,
                 []
               )
    end

    test "contract env matching folds case for both set and remove" do
      first_run = contract(env: %{"CONTRACT_KEY" => "true"})
      fixed = EnvPatch.fixed_keys(first_run)

      assert {:error, {:fixed, ["contract_key"]}} =
               EnvPatch.plan(%{}, %{"contract_key" => "false"}, [], owned(), fixed, [])

      assert {:error, {:fixed, ["Contract_Key"]}} =
               EnvPatch.plan(%{}, %{}, ["Contract_Key"], owned(), fixed, [])
    end

    test "a first-run forbidden_env key refuses a set, but a remove is cleanup" do
      first_run = contract(forbidden_env: ["FORBIDDEN_KEY"])
      forbidden = EnvPatch.forbidden_keys(first_run)

      assert {:error, {:forbidden, ["FORBIDDEN_KEY"]}} =
               EnvPatch.plan(%{}, %{"FORBIDDEN_KEY" => "true"}, [], owned(), [], forbidden)

      assert {:ok, plan} =
               EnvPatch.plan(
                 %{"FORBIDDEN_KEY" => "drifted", "KEEP" => "1"},
                 %{},
                 ["FORBIDDEN_KEY"],
                 owned(),
                 [],
                 forbidden
               )

      assert plan.remove == ["FORBIDDEN_KEY"]
      assert plan.removed == ["FORBIDDEN_KEY"]
      assert plan.merged == %{"KEEP" => "1"}
    end

    test "forbidden matching folds case too" do
      first_run = contract(forbidden_env: ["FORBIDDEN_KEY"])
      forbidden = EnvPatch.forbidden_keys(first_run)

      assert {:error, {:forbidden, ["forbidden_key"]}} =
               EnvPatch.plan(%{}, %{"forbidden_key" => "true"}, [], owned(), [], forbidden)
    end

    test "exact owned matching — a lowercase root_url is the user's key" do
      owned = owned(["ROOT_URL"])
      current = %{"ROOT_URL" => "https://platform"}

      assert {:error, {:owned, ["ROOT_URL"]}} =
               EnvPatch.plan(current, %{"ROOT_URL" => "https://evil"}, [], owned, [], [])

      assert {:ok, plan} = EnvPatch.plan(current, %{}, ["ROOT_URL"], owned, [], [])
      assert plan.skipped == ["ROOT_URL"]

      assert {:ok, lowered} =
               EnvPatch.plan(current, %{"root_url" => "https://app"}, [], owned, [], [])

      assert lowered.merged["root_url"] == "https://app"

      assert {:ok, removed} = EnvPatch.plan(lowered.merged, %{}, ["root_url"], owned, [], [])
      refute Map.has_key?(removed.merged, "root_url")
    end

    test "folded backing-url matching — a lowercase database_url is still owned" do
      owned = owned([], ["DATABASE_URL"])
      current = %{"DATABASE_URL" => "postgres://platform"}

      assert {:error, {:owned, ["database_url"]}} =
               EnvPatch.plan(current, %{"database_url" => "postgres://evil"}, [], owned, [], [])

      assert {:ok, plan} = EnvPatch.plan(current, %{}, ["database_url"], owned, [], [])
      assert plan.skipped == ["database_url"]
      assert plan.merged == current
    end
  end

  describe "message/1" do
    test "names owned keys and never values" do
      assert EnvPatch.message({:owned, ["DATABASE_URL", "ROOT_URL"]}) =~
               "managed by the platform"

      assert EnvPatch.message({:owned, ["DATABASE_URL"]}) =~ "DATABASE_URL"
    end

    test "names fixed and forbidden contract keys" do
      assert EnvPatch.message({:fixed, ["CONTRACT_KEY"]}) =~
               "fixed by the app's first-run contract and cannot be changed: CONTRACT_KEY"

      assert EnvPatch.message({:forbidden, ["FORBIDDEN_KEY"]}) =~
               "forbidden by the app's first-run contract: FORBIDDEN_KEY"
    end

    test "covers every refusal shape" do
      assert EnvPatch.message({:overlap, ["A"]}) =~ "both set and removed"
      assert EnvPatch.message({:invalid_name, ["BAD"]}) =~ "POSIX-shaped"
      assert EnvPatch.message({:invalid_value, ["A"]}) =~ "must be strings"
      assert EnvPatch.message({:invalid_set, "x"}) =~ "set must be an object"
      assert EnvPatch.message({:invalid_remove, "x"}) =~ "remove must be an array"
    end
  end

  describe "owned_keys/3" do
    test "no wiring row means the recipe keys are ordinary user keys" do
      owned = EnvPatch.owned_keys(instance(), version(oidc_wiring: wiring()), false)
      assert MapSet.size(owned.exact) == 0
      assert MapSet.size(owned.folded) == 0
    end

    test "a wiring row without a recipe owns no SSO keys" do
      owned = EnvPatch.owned_keys(instance(), version(oidc_wiring: nil), true)
      assert MapSet.size(owned.exact) == 0
    end

    test "a wiring row owns all four recipe keys exactly" do
      owned = EnvPatch.owned_keys(instance(), version(oidc_wiring: wiring()), true)

      assert owned.exact ==
               MapSet.new([
                 "SSO_AUTHORITY",
                 "SSO_CLIENT_ID",
                 "SSO_CLIENT_SECRET",
                 "SSO_ENABLED"
               ])
    end

    test "an absent optional enabled_env is not a key" do
      owned =
        EnvPatch.owned_keys(
          instance(),
          version(oidc_wiring: wiring(enabled_env: nil)),
          true
        )

      refute MapSet.member?(owned.exact, "SSO_ENABLED")
    end

    test "backing-service url_env keys fold; the version's instance_url_env is exact" do
      host = instance(backing_services: [%{url_env: "DATABASE_URL"}, %{url_env: "REDIS_URL"}])
      owned = EnvPatch.owned_keys(host, version(instance_url_env: "ROOT_URL"), false)

      assert owned.exact == MapSet.new(["ROOT_URL"])
      assert owned.folded == MapSet.new(["database_url", "redis_url"])
    end

    test "the first-run contract is not in the deployer-owned set" do
      owned =
        EnvPatch.owned_keys(
          instance(),
          version(first_run: contract(env: %{"CONTRACT_KEY" => "true"})),
          false
        )

      assert MapSet.size(owned.exact) == 0
      assert MapSet.size(owned.folded) == 0
    end
  end

  describe "contract key sets" do
    test "a nil contract has no fixed or forbidden keys" do
      assert EnvPatch.fixed_keys(nil) == MapSet.new()
      assert EnvPatch.forbidden_keys(nil) == MapSet.new()
    end

    test "fixed keys are the contract env names; forbidden keys its forbidden names" do
      first_run = contract(env: %{"A" => "1", "B" => "2"}, forbidden_env: ["C"])

      assert EnvPatch.fixed_keys(first_run) == MapSet.new(["A", "B"])
      assert EnvPatch.forbidden_keys(first_run) == MapSet.new(["C"])
    end
  end
end
