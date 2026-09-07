defmodule FluxVale.Ops.FeatureFlagsTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.Ops.FeatureFlags

  # @known_flags ships empty (mechanism-first, #25): the decision table is
  # exercised through the pure core `decide/3` with an action-created row —
  # the edge `enabled?/2` is declare-gated and its happy path returns with
  # the first real flag (M3+). The undeclared/non-atom guards below are the
  # edge behavior that exists today.
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

  describe "enable/2 disable/2 (FunWithFlags-style verbs, Am. 4)" do
    # Declare-gated like enabled?'s happy path, these return with the first
    # real flag (M3+): create-on-enable, percentage set/preserve, invalid
    # percentage failing validation on update too, disable keeps pct,
    # non-admin actor forbidden (policy already covered in
    # feature_flag_test.exs), and the `actor:`-required KeyError. The
    # guard rail that exists today is the declare gate.

    test "refuse undeclared keys — never mint a row no read can reach" do
      assert_raise ArgumentError, ~r/undeclared feature flag :no_such_flag/, fn ->
        FeatureFlags.enable(:no_such_flag, actor: nil)
      end

      assert_raise ArgumentError, ~r/undeclared feature flag :no_such_flag/, fn ->
        FeatureFlags.disable(:no_such_flag, actor: nil)
      end
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
