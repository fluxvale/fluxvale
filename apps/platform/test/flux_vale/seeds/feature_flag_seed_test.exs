defmodule FluxVale.Seeds.FeatureFlagSeedTest do
  @moduledoc """
  The feature-flag seed flow (`FluxVale.Seeds.seed_feature_flags!/0`)
  against a sandboxed DB (#597 S6) — create-if-missing only: the first
  run enables the flag, a re-seed writes nothing, and an operator's
  deliberate off is never reverted.
  """

  # Sync: a seed writes shared rows, so it must not overlap another test.

  use FluxVale.DataCase, async: false

  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.Seeds

  require Ash.Query

  @key "pocketid_sso_wiring"

  describe "seed_feature_flags!/0" do
    test "the first run creates the flag row, enabled" do
      assert :ok == Seeds.seed_feature_flags!()

      assert {:ok, %FeatureFlag{enabled: true}} = FeatureFlag.by_key(@key, authorize?: false)
      assert FeatureFlags.enabled?(:pocketid_sso_wiring)
    end

    test "a re-seed is a no-op, no new version rows for the flag (ADR-0048)" do
      assert :ok == Seeds.seed_feature_flags!()
      {:ok, flag} = FeatureFlag.by_key(@key, authorize?: false)
      assert length(versions!(flag.id)) == 1

      assert :ok == Seeds.seed_feature_flags!()

      assert length(versions!(flag.id)) == 1
    end

    test "create-only: a deliberate off is never converged back on" do
      FeatureFlag.create!(@key, %{enabled: false}, authorize?: false)
      refute FeatureFlags.enabled?(:pocketid_sso_wiring)

      assert :ok == Seeds.seed_feature_flags!()

      assert {:ok, %FeatureFlag{enabled: false}} = FeatureFlag.by_key(@key, authorize?: false)
      refute FeatureFlags.enabled?(:pocketid_sso_wiring)
    end
  end

  defp versions!(source_id) do
    FeatureFlag.Version
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.read!(authorize?: false)
  end
end
