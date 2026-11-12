defmodule FluxVale.Seeds.FeatureFlagsSeedTest do
  @moduledoc """
  The feature-flag seed flow (`FluxVale.Seeds.seed_feature_flags!/0`)
  against a sandboxed DB (#597 S6) — the seeded rows exist enabled, the
  seed is idempotent, and every seeded flag is in the declared catalog.
  """

  # Sync: a seed writes shared rows, so it must not overlap another test.

  use FluxVale.DataCase, async: false

  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.Seeds

  require Ash.Query

  describe "seed_feature_flags!/0" do
    test "creates each seeded flag enabled" do
      assert :ok == Seeds.seed_feature_flags!()

      for flag <- Seeds.seeded_feature_flags() do
        key = Atom.to_string(flag)

        assert {:ok, %FeatureFlag{enabled: true}} = FeatureFlag.by_key(key, authorize?: false)
      end
    end

    test "re-seeding leaves exactly one row per key" do
      assert :ok == Seeds.seed_feature_flags!()
      assert :ok == Seeds.seed_feature_flags!()

      for flag <- Seeds.seeded_feature_flags() do
        assert [%FeatureFlag{}] = rows_for(Atom.to_string(flag))
      end
    end

    test "every seeded flag is declared in the catalog" do
      for flag <- Seeds.seeded_feature_flags() do
        assert flag in FeatureFlags.known_flags()
      end
    end
  end

  defp rows_for(key) do
    FeatureFlag
    |> Ash.Query.filter(key == ^key)
    |> Ash.read!(authorize?: false)
  end
end
