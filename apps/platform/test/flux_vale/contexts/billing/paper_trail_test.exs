defmodule FluxVale.Billing.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Billing (#645, the plan's A2-S2 slice):
  # the money lifecycles write attributed version rows. The waiver flip
  # names its admin, the goodwill grant versions twice (the admin's
  # action row plus the posting machinery's own honest system row), and
  # the gateway path records the honest nil actor. Mirrors the Ops
  # suite (the A2-S1 exemplar): version-row reads that assert STORAGE
  # run authorize?: false; the D7 version-read policy is pinned there.

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Topup
  alias FluxVale.Billing.Wallet
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  defp versions!(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  describe "money lifecycles leave attributed evidence" do
    test "a set_waiver update produces a version attributed to the admin actor" do
      admin = AccountsFixtures.admin!()
      {_org, wallet} = BillingFixtures.funded_wallet!()

      wallet
      |> Ash.Changeset.for_update(:set_waiver, %{paywall_waived: true}, actor: admin)
      |> Ash.update!()

      [create_version, waiver_version] = versions!(Wallet.Version, wallet.id)

      # The wallet is born of the provisioning seam (EnsureWallet, the
      # system path) — its create-version carries the honest nil actor.
      assert create_version.version_action_type == :create
      assert is_nil(create_version.user_id)

      assert waiver_version.version_action_name == :set_waiver
      assert waiver_version.changes == %{"paywall_waived" => true}
      assert waiver_version.version_action_inputs == %{"paywall_waived" => true}
      assert waiver_version.user_id == admin.id
      assert waiver_version.actor_label == admin.username
    end

    test "a grant_goodwill create produces create-versions: the admin's action row and the posting machinery's system row" do
      admin = AccountsFixtures.admin!()
      {_org, wallet} = BillingFixtures.funded_wallet!()

      {:ok, entry} =
        LedgerEntry
        |> Ash.Changeset.for_create(:grant_goodwill, %{wallet_id: wallet.id, amount_cents: 500},
          actor: admin
        )
        |> Ash.create()

      versions = versions!(LedgerEntry.Version, entry.id)

      # One manual write, two version rows (observed, pinned): the
      # action-level row (action name :grant_goodwill, the admin's
      # arguments, admin attribution) and the row the posting seam
      # actually wrote (action name :create — PostEntry runs
      # authorize?: false, so its attribution is honestly nil).
      assert length(versions) == 2

      action_row = Enum.find(versions, &(&1.version_action_name == :grant_goodwill))
      posting_row = Enum.find(versions, &(&1.version_action_name == :create))

      assert action_row.version_action_type == :create
      assert action_row.version_action_inputs["amount_cents"] == 500
      assert action_row.user_id == admin.id
      assert action_row.actor_label == admin.username

      assert posting_row.version_action_inputs["amount"] == 500
      assert posting_row.version_action_inputs["reason"] == "adjustment"
      assert posting_row.version_action_inputs["type"] == "credit"
      assert is_nil(posting_row.user_id)
      assert is_nil(posting_row.actor_label)
    end

    test "a gateway-path topup create records the honest nil actor" do
      {org, _user} = BillingFixtures.grant_free_org!()

      # The gateway path (StartTopup) creates the row system-side,
      # authorize?: false with no actor — mirrored here.
      topup =
        Topup
        |> Ash.Changeset.for_create(:create, %{organization_id: org.id, amount_cents: 1000},
          authorize?: false
        )
        |> Ash.create!()

      [version] = versions!(Topup.Version, topup.id)

      assert version.version_action_type == :create
      assert is_nil(version.user_id)
      assert is_nil(version.actor_label)
      assert version.version_action_inputs["amount_cents"] == 1000
    end
  end
end
