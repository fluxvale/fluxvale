defmodule FluxVale.Ops.FeatureFlagsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.Ops.FeatureFlags

  # @known_flags carries its first real flag (:pocketid_sso_wiring,
  # #597 S2) — the declare-gated happy paths are exercised against it
  # below, alongside the pure decide/3 decision table. The
  # undeclared/non-atom guards are the edge behavior that always
  # existed.
  setup do
    user = User.create!("flagged-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

    # One real row through the action (repo convention); per-case shapes are
    # pure struct updates — decide/3 is the pure core, row shape is its input.
    row = FeatureFlag.create!("swept_key", %{enabled: true}, authorize?: false)

    %{user: user, row: row}
  end

  defp flag(row, attrs), do: struct!(row, attrs)

  describe "enabled?/2 (the declare-gated edge)" do
    test "raises on undeclared keys — a typo'd flag is a code bug, not a closed flag" do
      assert_raise ArgumentError, ~r/undeclared feature flag :no_such_flag/, fn ->
        FeatureFlags.enabled?(:no_such_flag)
      end

      # …with an actor too (FunWithFlags signature, ADR-0023 Am. 4)
      assert_raise ArgumentError, ~r/undeclared feature flag :no_such_flag/, fn ->
        FeatureFlags.enabled?(:no_such_flag, for: nil)
      end
    end

    test "accepts atoms only" do
      # Enum.at keeps the deliberate type violation out of the compiler's
      # literal-typing — a typed call would emit a spec warning, and apply/3
      # trips credo's Refactor.Apply check.
      bad_key = Enum.at(["a_string_key"], 0)

      assert_raise FunctionClauseError, fn ->
        FeatureFlags.enabled?(bad_key)
      end
    end
  end

  # The first declared flag (#597 S2): the happy paths the
  # mechanism-first ignores guarded are real and covered now.
  describe "enabled?/2 with :pocketid_sso_wiring (#597's flag)" do
    test "missing row = disabled — fail-closed is the shipped default" do
      refute FeatureFlags.enabled?(:pocketid_sso_wiring)
      refute FeatureFlags.enabled?(:pocketid_sso_wiring, for: nil)
    end

    test "an enabled row means on — everyone, anonymous included", %{user: user} do
      FeatureFlag.create!("pocketid_sso_wiring", %{enabled: true}, authorize?: false)

      assert FeatureFlags.enabled?(:pocketid_sso_wiring)
      assert FeatureFlags.enabled?(:pocketid_sso_wiring, for: user)
      assert FeatureFlags.enabled?(:pocketid_sso_wiring, for: nil)
    end

    test "a disabled row means off", %{user: user} do
      FeatureFlag.create!("pocketid_sso_wiring", %{enabled: false}, authorize?: false)

      refute FeatureFlags.enabled?(:pocketid_sso_wiring, for: user)
    end
  end

  describe "enable/2 disable/2 (FunWithFlags-style verbs, Am. 4)" do
    test "refuse undeclared keys — never mint a row no read can reach" do
      assert_raise ArgumentError, ~r/undeclared feature flag :no_such_flag/, fn ->
        FeatureFlags.enable(:no_such_flag, actor: nil)
      end

      assert_raise ArgumentError, ~r/undeclared feature flag :no_such_flag/, fn ->
        FeatureFlags.disable(:no_such_flag, actor: nil)
      end
    end
  end

  describe "enable/2 with the declared flag" do
    test "a platform admin creates the row on", %{user: user} do
      admin =
        User.create!(
          "admin-#{System.unique_integer()}@fluxvale.com",
          %{platform_role: :admin},
          authorize?: false
        )

      assert :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: admin)
      assert FeatureFlags.enabled?(:pocketid_sso_wiring, for: user)

      # Enable again on the existing row: idempotent, percentage kept.
      assert :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: admin, percentage: 50)

      assert {:ok, %FeatureFlag{enabled: true, rollout_percentage: 50}} =
               FeatureFlag.by_key("pocketid_sso_wiring", authorize?: false)
    end

    test "a non-admin actor is Forbidden — the verbs are operator-only", %{user: user} do
      assert {:error, %Ash.Error.Forbidden{}} =
               FeatureFlags.enable(:pocketid_sso_wiring, actor: user)
    end
  end

  describe "disable/2 with the declared flag" do
    test "an admin turns a row off; the rollout percentage survives for a later enable",
         %{user: user} do
      admin =
        User.create!(
          "admin-#{System.unique_integer()}@fluxvale.com",
          %{platform_role: :admin},
          authorize?: false
        )

      :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: admin, percentage: 25)
      assert :ok = FeatureFlags.disable(:pocketid_sso_wiring, actor: admin)

      refute FeatureFlags.enabled?(:pocketid_sso_wiring, for: user)

      assert {:ok, %FeatureFlag{enabled: false, rollout_percentage: 25}} =
               FeatureFlag.by_key("pocketid_sso_wiring", authorize?: false)
    end

    test "no row = already disabled by absence — :ok, nothing materialized" do
      assert :ok = FeatureFlags.disable(:pocketid_sso_wiring, actor: nil)

      assert {:error, _missing} =
               FeatureFlag.by_key("pocketid_sso_wiring", authorize?: false)
    end
  end

  describe "decide/3 — missing and disabled (fail-closed)" do
    test "missing row means disabled everywhere", %{user: user} do
      refute FeatureFlags.decide(nil, :swept_key, user)
      refute FeatureFlags.decide(nil, :swept_key, nil)
    end

    test "disabled row means disabled for everyone", %{user: user, row: row} do
      row
      |> flag(enabled: false)
      |> FeatureFlags.decide(:swept_key, user)
      |> refute()
    end
  end

  describe "decide/3 — enabled with nil rollout_percentage" do
    test "everyone, anonymous included", %{user: user, row: row} do
      row
      |> flag(rollout_percentage: nil)
      |> FeatureFlags.decide(:swept_key, user)
      |> assert()

      row
      |> flag(rollout_percentage: nil)
      |> FeatureFlags.decide(:swept_key, nil)
      |> assert()
    end
  end

  describe "decide/3 — percentage boundaries" do
    test "0% is nobody, 100% is everybody", %{user: user, row: row} do
      row
      |> flag(rollout_percentage: 0)
      |> FeatureFlags.decide(:swept_key, user)
      |> refute()

      row
      |> flag(rollout_percentage: 100)
      |> FeatureFlags.decide(:swept_key, user)
      |> assert()
    end

    test "anonymous actors fail closed on partial rollouts (nothing to bucket)", %{row: row} do
      row
      |> flag(rollout_percentage: 100)
      |> FeatureFlags.decide(:swept_key, nil)
      |> refute()

      row
      |> flag(rollout_percentage: 50)
      |> FeatureFlags.decide(:swept_key, nil)
      |> refute()
    end

    test "id-less actor maps fail closed too — the spec admits any map (CodeRabbit, #36)",
         %{row: row} do
      row
      |> flag(rollout_percentage: 50)
      |> FeatureFlags.decide(:swept_key, %{name: "no id here"})
      |> refute()
    end
  end

  describe "decide/3 — sticky rollouts (ADR-0023 §2)" do
    test "same actor, same answer — across calls and across the pct sweep", %{
      user: user,
      row: row
    } do
      at_50 = flag(row, rollout_percentage: 50)

      assert FeatureFlags.decide(at_50, :swept_key, user) ==
               FeatureFlags.decide(at_50, :swept_key, user)

      # The sweep is monotone with a single step: rem(phash2) is fixed per
      # {key, user}, so an actor flips on exactly once as pct rises — and
      # never flips back. No hash-value coupling: any user, any key.
      results =
        for pct <- 0..100 do
          row
          |> flag(rollout_percentage: pct)
          |> FeatureFlags.decide(:swept_key, user)
        end

      {falses, trues} = Enum.split_with(results, &(!&1))
      assert [false] == [hd(results)] and [true] == [List.last(results)]
      assert Enum.all?(falses, &(!&1))
      assert Enum.all?(trues, & &1)
      assert falses ++ trues == results
    end

    test "actors bucket independently — a partial rollout really splits users", %{row: row} do
      # 100 synthetic actors (pure core: any map with an id is an actor),
      # pct 50: phash2 buckets uniformly, so both sides are populated.
      actors = for _i <- 1..100, do: %{id: Ash.UUIDv7.generate()}
      partial = flag(row, rollout_percentage: 50)

      # Membership, not counts: both sides populated (phash2 buckets
      # uniformly; deterministic under the pinned toolchain, so not flaky).
      results = for actor <- actors, do: FeatureFlags.decide(partial, :swept_key, actor)
      assert true in results and false in results
    end
  end
end
