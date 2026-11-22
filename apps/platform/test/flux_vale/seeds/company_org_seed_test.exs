defmodule FluxVale.Seeds.CompanyOrgSeedTest do
  @moduledoc """
  The company-organization seed (#879): fresh installs mint the brand
  org (`fluxvale`, admin-owned, born paywall-waived — #869's steady
  state, which the owner re-established by hand after the Nov 17
  wipe) instead of leaving it to the operator.

  These tests are the dry run for the post-land wipe: both envs will
  be re-created fresh and the seed must deliver the company org with
  no manual flips during acceptance.
  """

  # async: false — the seed writes the fixed fluxvale slug and every
  # test reads it back; the seed rule (#667, #669 class).
  use FluxVale.DataCase, async: false

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Identity.User
  alias FluxVale.Seeds
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "seed_company_org!/0" do
    test "fresh install: the company org exists, admin-owned, team-shaped" do
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_company_org!()

      org = company_org!()
      assert org.slug == "fluxvale"
      assert org.name == "FluxVale"

      # Team org: the personal marker is provisioning's to stamp (#408)
      # — the admin's personal org stays the JIT admin-slug one (#878).
      assert is_nil(org.personal_owner_id)

      admin = seeded_admin!()
      assert [membership] = memberships(org.id)
      assert membership.user_id == admin.id
      assert membership.role == :owner

      {:ok, personal} = Accounts.personal_org_for_user(admin.id, authorize?: false)
      assert personal.id != org.id
      assert personal.slug == "admin"
    end

    test "born paywall_waived — #869's steady state, no manual flip" do
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_company_org!()

      {:ok, wallet} = Billing.ensure_wallet(company_org!())
      assert wallet.paywall_waived
    end

    test "idempotent — a second run is a no-op" do
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_company_org!()

      org = company_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)

      :ok = Seeds.seed_company_org!()

      assert company_org!().id == org.id
      assert length(memberships(org.id)) == 1

      # The waiver write never re-fires: the row is byte-identical
      # (updated_at is usec-precise, a rewrite would move it).
      {:ok, again} = Billing.ensure_wallet(org)
      assert again.updated_at == wallet.updated_at
      assert again.paywall_waived
    end

    test "an operator's OFF flip is final — the seed never re-converges" do
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_company_org!()

      {:ok, wallet} = Billing.ensure_wallet(company_org!())
      Wallet.set_waiver(wallet, %{paywall_waived: false}, actor: seeded_admin!())

      :ok = Seeds.seed_company_org!()

      {:ok, reloaded} = Billing.ensure_wallet(company_org!())
      refute reloaded.paywall_waived
    end

    test "the brand reservation still refuses actor claims — before and after the seed mints it" do
      stranger = AccountsFixtures.user!()

      # Before: no org holds the slug, so the reservation is the only
      # fence — and it refuses (the seed never weakens it).
      assert {:error, %Ash.Error.Invalid{errors: before_errors}} =
               Accounts.create_organization(stranger, %{name: "Mine", slug: "fluxvale"})

      assert Enum.any?(
               before_errors,
               &match?(
                 %Ash.Error.Changes.InvalidAttribute{field: :slug, message: "is reserved"},
                 &1
               )
             )

      # The seed mints the slug through the system :create — the
      # action actors cannot reach (its policy forbids every actor).
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_company_org!()

      # After: the slug is doubly unclaimable for the actor — reserved
      # by the list, taken by the unique_slug identity. Either fence
      # refusing is the contract; assert the field-level refusal.
      assert {:error, %Ash.Error.Invalid{errors: after_errors}} =
               Accounts.create_organization(stranger, %{name: "Mine", slug: "fluxvale"})

      assert Enum.any?(
               after_errors,
               &match?(%Ash.Error.Changes.InvalidAttribute{field: :slug}, &1)
             )
    end

    test "an admin-owned org on the slug is adopted untouched (the hand-created state)" do
      :ok = Seeds.seed_admin!()

      # The post-wipe manual shape: the operator's own create through
      # the #754 admin exemption, wallet provisioned, waiver
      # deliberately OFF (operator data).
      {:ok, hand} =
        Accounts.create_organization(seeded_admin!(), %{name: "FluxVale Co", slug: "fluxvale"})

      {:ok, wallet} = Billing.ensure_wallet(hand)
      Wallet.set_waiver(wallet, %{paywall_waived: false}, actor: seeded_admin!())

      :ok = Seeds.seed_company_org!()

      # Adopted by existence: nothing converged, no membership minted,
      # the OFF waiver is final.
      assert Organization.get_by_slug!("fluxvale", authorize?: false).id == hand.id
      assert length(memberships(hand.id)) == 1

      {:ok, again} = Billing.ensure_wallet(hand)
      refute again.paywall_waived
    end

    test "a wallet-less adopted org stays wallet-less — the never-touch stance, pinned" do
      # The actor path provisions no wallet (lazy, #408): an org
      # hand-created then seeded before any billing surface touched it
      # is adopted untouched — no wallet minted, so the paywall is NOT
      # waived until an operator flips it. Deliberate (the seed never
      # converges an adopted org's wallet), pinned so the edge is
      # known, not silent.
      :ok = Seeds.seed_admin!()

      Accounts.create_organization(seeded_admin!(), %{name: "FluxVale Co", slug: "fluxvale"})

      :ok = Seeds.seed_company_org!()

      assert {:error, _not_found} =
               Wallet.get_by_organization(company_org!().id, authorize?: false)
    end

    test "a stranger's org on the brand slug fails loudly — the squatter posture" do
      :ok = Seeds.seed_admin!()

      # Org rename carries no reservations (ReservedSlug's accepted
      # asymmetry), so a stranger CAN legitimately land on the slug —
      # the seed names it and refuses instead of silently adopting.
      stranger = AccountsFixtures.user!()

      {:ok, org} =
        Accounts.create_organization(stranger, %{name: "Squatters Inc", slug: "squatters-inc"})

      org
      |> Ash.Changeset.for_update(:update, %{slug: "fluxvale"}, actor: stranger)
      |> Ash.update!()

      assert_raise RuntimeError, ~r/held by another owner/, fn ->
        Seeds.seed_company_org!()
      end

      # Nothing was disturbed — the operator resolves it, not the seed.
      assert Organization.get_by_slug!("fluxvale", authorize?: false).id == org.id
    end
  end

  describe "seed/0" do
    test "the company org rides the promotable path" do
      # Delegation guard: dropping seed_company_org!/0 from seed/0 must
      # fail here, not at the post-wipe bring-up.
      :ok = Seeds.seed()

      org = company_org!()
      assert [membership] = memberships(org.id)
      assert membership.user_id == seeded_admin!().id
      assert membership.role == :owner

      {:ok, wallet} = Billing.ensure_wallet(org)
      assert wallet.paywall_waived
    end
  end

  defp seeded_admin! do
    User.get_by_email!("admin@fluxvale.com", authorize?: false)
  end

  defp company_org! do
    Organization.get_by_slug!("fluxvale", authorize?: false)
  end

  defp memberships(org_id) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org_id)
    |> Ash.read!(authorize?: false)
  end
end
