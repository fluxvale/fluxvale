defmodule FluxVale.Ops.FeatureFlagTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Ops.FeatureFlag

  # Preconditions run authorize?: false (repo convention — mirrors the seeds
  # bootstrap); the policy itself is what's under test below.
  defp admin do
    case User.get_by_email("admin@fluxvale.com", authorize?: false) do
      {:ok, existing} ->
        existing

      {:error, _not_found} ->
        User.create!("admin@fluxvale.com", %{platform_role: :admin}, authorize?: false)
    end
  end

  defp regular_user do
    User.create!("regular-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  describe "create/2" do
    test "defaults enabled to false (ADR-0023 §2: new behavior starts off)" do
      assert {:ok, %FeatureFlag{enabled: false, rollout_percentage: nil}} =
               FeatureFlag.create("new_thing", %{description: "gates the new thing"},
                 authorize?: false
               )
    end

    test "enforces unique keys" do
      FeatureFlag.create!("dup_key", %{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               FeatureFlag.create("dup_key", %{}, authorize?: false)
    end

    test "rejects keys that could never match a declared atom (code-shaped only)" do
      assert {:error, %Ash.Error.Invalid{}} =
               FeatureFlag.create("My Flag", %{}, authorize?: false)
    end

    test "bounds rollout_percentage to 0..100" do
      assert {:error, %Ash.Error.Invalid{}} =
               FeatureFlag.create("pct_low", %{rollout_percentage: -1}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               FeatureFlag.create("pct_high", %{rollout_percentage: 101}, authorize?: false)

      assert {:ok, _edge} =
               FeatureFlag.create("pct_edges", %{rollout_percentage: 100}, authorize?: false)
    end
  end

  describe "by_key/1" do
    test "fetches the row the evaluator will consult" do
      created = FeatureFlag.create!("fetched_key", %{}, authorize?: false)

      # by_key! + not_found_error?: false — the exact evaluator call shape
      assert FeatureFlag.by_key!("fetched_key", authorize?: false, not_found_error?: false).id ==
               created.id

      assert FeatureFlag.by_key!("no_such_key", authorize?: false, not_found_error?: false) ==
               nil
    end
  end

  describe "policy (ADR-0027: mutations ride ActorIsPlatformAdmin)" do
    setup do
      %{admin: admin(), regular: regular_user()}
    end

    test "non-admins are denied everything, default-deny", %{regular: regular} do
      flag = FeatureFlag.create!("guarded_key", %{}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               FeatureFlag.create("blocked_key", %{}, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(flag, %{enabled: true}, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(flag, actor: regular, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(FeatureFlag, actor: regular, authorize?: true)

      # Anonymous browsing AshAdmin sees nothing either
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(FeatureFlag, authorize?: true)
    end

    test "admins create, toggle, and destroy — the paths AshAdmin rides", %{admin: admin} do
      assert {:ok, flag} =
               FeatureFlag.create("toggled_key", %{rollout_percentage: 50},
                 actor: admin,
                 authorize?: true
               )

      # The flip-live exit criterion at the action level: AshAdmin's toggle
      # is this update, and the evaluator is uncached — decide flips with it.
      assert {:ok, flipped} = Ash.update(flag, %{enabled: true}, actor: admin, authorize?: true)
      assert flipped.enabled

      assert {:ok, [_row]} = Ash.read(FeatureFlag, actor: admin, authorize?: true)
      assert :ok = Ash.destroy(flipped, actor: admin, authorize?: true)
    end
  end
end
