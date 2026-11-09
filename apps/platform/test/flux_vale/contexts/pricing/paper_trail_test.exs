defmodule FluxVale.Pricing.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Pricing (#645, the plan's A2-S2 slice):
  # changes_only keeps the diff exact, and the ATOMIC PATH (the watch
  # item) versions with inputs and attribution intact. Mirrors the Ops
  # suite (the A2-S1 exemplar): version-row reads that assert STORAGE
  # run authorize?: false; the D7 version-read policy is pinned there.

  use FluxVale.DataCase, async: true

  alias FluxVale.Pricing.Size
  alias FluxVale.Pricing.TaxRate
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  defp versions!(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp rate!(country, rate_bp) do
    TaxRate
    |> Ash.Changeset.for_create(
      :create,
      %{country: country, rate_bp: rate_bp, effective_from: DateTime.utc_now(:microsecond)},
      authorize?: false
    )
    |> Ash.create!()
  end

  describe "the exact diff" do
    test "a size update versions exactly the changed attributes (changes_only)" do
      admin = AccountsFixtures.admin!()
      n = System.unique_integer([:positive])

      size =
        Size
        |> Ash.Changeset.for_create(
          :create,
          %{
            slug: "pt-#{n}",
            cpu_cores: Decimal.new("1.0"),
            memory_mb: 1024,
            monthly_cents: 500
          },
          authorize?: false
        )
        |> Ash.create!()

      size
      |> Ash.Changeset.for_update(:update, %{monthly_cents: 600, memory_mb: 2048}, actor: admin)
      |> Ash.update!()

      [_create_version, update_version] = versions!(Size.Version, size.id)

      assert update_version.version_action_name == :update
      # changes_only: just the diff, not a snapshot (D6)
      assert update_version.changes == %{"monthly_cents" => 600, "memory_mb" => 2048}
      assert update_version.user_id == admin.id
    end
  end

  describe "the atomic path (the watch item)" do
    test "a bulk update through the atomic-capable action versions each record with inputs and attribution intact" do
      # version_action_inputs on the atomic path (#651's disclosed
      # quirk class — nil-map vs values): OBSERVED on ash_paper_trail
      # 0.8.1 + ash 3.37.3 the VALUES arrive, %{"rate_bp" => 2100}, not
      # an empty map. Pinned as observed, not "fixed".
      admin = AccountsFixtures.admin!()

      r1 = rate!("QZ", 2000)
      r2 = rate!("XW", 1900)

      TaxRate
      |> Ash.Query.filter(country in ^[r1.country, r2.country])
      |> Ash.bulk_update!(:update, %{rate_bp: 2100}, actor: admin)

      for rate <- [r1, r2] do
        [_create_version, update_version] = versions!(TaxRate.Version, rate.id)

        assert update_version.version_action_type == :update
        assert update_version.version_action_inputs == %{"rate_bp" => 2100}
        assert update_version.changes == %{"rate_bp" => 2100}
        assert update_version.user_id == admin.id
        assert update_version.actor_label == admin.username
      end
    end

    test "an identical-value resubmission still versions — the quirk rides atomic-capable actions" do
      # Upstream 0.8.1 semantics, pinned (the Ops suite's quirk, re-observed
      # here on an atomic-capable update): `context.changed?` is
      # changeset-shaped, so resubmitting the same values writes a row.
      # The Catalog updates carry require_atomic?(false) and do NOT
      # version a resubmission (pinned in the Catalog suite) — this
      # action class is where the quirk manifests.
      admin = AccountsFixtures.admin!()
      rate = rate!("QZ", 2000)

      updated =
        rate
        |> Ash.Changeset.for_update(:update, %{rate_bp: 1800}, actor: admin)
        |> Ash.update!()

      _resubmitted =
        updated
        |> Ash.Changeset.for_update(:update, %{rate_bp: 1800}, actor: admin)
        |> Ash.update!()

      # create + first update + the resubmission's extra row
      assert length(versions!(TaxRate.Version, rate.id)) == 3
    end
  end
end
