defmodule FluxVale.Accounts.Operations.CreateOrganizationTest do
  @moduledoc """
  The #408 actor-driven creation seam: `Accounts.create_organization/2`
  makes the caller a team org's single `:owner` member in-transaction —
  no personal marker, no wallet, no credits (the signup grant is
  per-user; the org is the abuse boundary) — with the slug discipline
  (taken/reserved/39-cap/format) and the name cap binding this path at
  creation.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.ActorBelowOrgCreateCap
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "happy path" do
    test "creates the org with the creator as its single :owner member" do
      user = AccountsFixtures.user!()

      assert {:ok, org} =
               Accounts.create_organization(user, %{name: "Team Org", slug: "team-org"})

      assert org.name == "Team Org"
      assert org.slug == "team-org"

      memberships = memberships(org)
      assert length(memberships) == 1

      member = hd(memberships)
      assert member.user_id == user.id
      assert member.role == :owner
    end

    test "the org is a team org — the personal marker stays null" do
      user = AccountsFixtures.user!()

      assert {:ok, org} =
               Accounts.create_organization(user, %{name: "Team Org", slug: "marker-null"})

      # Fresh read: the marker is a create-time fact, and this path
      # never writes it (provisioning is the only stamper).
      assert {:ok, fresh} = Organization.get_by_id(org.id, authorize?: false)
      assert fresh.personal_owner_id == nil
    end

    test "the marker cannot ride the actor path's input" do
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.create_organization(user, %{
                 name: "Team Org",
                 slug: "marker-input",
                 personal_owner_id: user.id
               })
    end

    test "no wallet and no ledger rows — billing waits for a billing surface" do
      user = AccountsFixtures.user!()

      assert {:ok, org} =
               Accounts.create_organization(user, %{name: "Team Org", slug: "lazy-billing"})

      assert wallets(org) == []

      # Ledger entries hang off wallets (append-only, wallet-keyed), so
      # a wallet-less org has no rows — asserted directly anyway.
      assert ledger_entries(org) == []
    end
  end

  describe "the per-user cap (#408)" do
    test "a user with 10 owned orgs is refused — the cap policy surfaces" do
      # The JIT personal org is the first owned one; 9 more make 10.
      user = AccountsFixtures.user!()
      Enum.each(1..9, fn _n -> AccountsFixtures.owned_org!(user) end)

      assert {:error, %Ash.Error.Forbidden{errors: errors}} =
               Accounts.create_organization(user, %{name: "Over", slug: "cap-over"})

      assert Enum.any?(errors, fn
               %Ash.Error.Forbidden.Policy{policies: policies} ->
                 Enum.any?(policies, &(&1.description =~ "org-creation cap"))

               _other ->
                 false
             end)

      # The check's own message (the per-check breakdown Ash renders
      # only on explicit-forbid chains) — pinned here so the cap text
      # cannot drift silently.
      assert ActorBelowOrgCreateCap.describe([]) == "actor owns fewer than 10 organizations"
    end

    test "a user with 9 owned orgs succeeds" do
      user = AccountsFixtures.user!()
      Enum.each(1..8, fn _n -> AccountsFixtures.owned_org!(user) end)

      assert {:ok, org} =
               Accounts.create_organization(user, %{name: "Under", slug: "cap-under"})

      assert owned_count(user) == 10
      assert hd(memberships(org)).role == :owner
    end
  end

  describe "slug rules (actor path)" do
    test "a taken slug fails field-scoped" do
      org = AccountsFixtures.owned_org!(AccountsFixtures.user!())
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Accounts.create_organization(user, %{name: "Clone", slug: org.slug})

      assert Enum.any?(
               errors,
               &match?(
                 %Ash.Error.Changes.InvalidAttribute{
                   field: :slug,
                   message: "has already been taken"
                 },
                 &1
               )
             )
    end

    test "reserved slugs fail with 'is reserved'" do
      user = AccountsFixtures.user!()

      # Middles plus the ends of the list ("www" opens it, "new" closes
      # it — the literal /organizations/new route's word, the route is
      # why it is reserved).
      for slug <- ["www", "api", "billing", "organizations", "fluxvale", "new"] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 Accounts.create_organization(user, %{name: "Reserved", slug: slug}),
               "expected #{slug} to be reserved"

        assert Enum.any?(
                 errors,
                 &match?(
                   %Ash.Error.Changes.InvalidAttribute{field: :slug, message: "is reserved"},
                   &1
                 )
               )
      end
    end

    test "a 40-char slug fails the creation cap; 39 passes" do
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Accounts.create_organization(user, %{name: "Long", slug: String.duplicate("a", 40)})

      assert Enum.any?(
               errors,
               &match?(
                 %Ash.Error.Changes.InvalidAttribute{
                   field: :slug,
                   message: "must be at most 39 characters"
                 },
                 &1
               )
             )

      assert {:ok, org} =
               Accounts.create_organization(user, %{name: "Fits", slug: String.duplicate("b", 39)})

      assert String.length(org.slug) == 39
    end

    test "invalid characters fail the shared format rule" do
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Accounts.create_organization(user, %{name: "Bad", slug: "under_score"})

      assert Enum.any?(
               errors,
               &match?(
                 %Ash.Error.Changes.InvalidAttribute{
                   field: :slug,
                   message: "must contain only lowercase alphanumeric characters and hyphens"
                 },
                 &1
               )
             )
    end
  end

  describe "name cap (actor path)" do
    test "a 101-char name fails at creation" do
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Accounts.create_organization(user, %{
                 name: String.duplicate("n", 101),
                 slug: "name-cap"
               })

      assert Enum.any?(
               errors,
               &match?(
                 %Ash.Error.Changes.InvalidAttribute{
                   field: :name,
                   message: "must be at most 100 characters"
                 },
                 &1
               )
             )
    end
  end

  defp memberships(org) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id)
    |> Ash.read!(authorize?: false)
  end

  defp owned_count(user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user.id and role == :owner)
    |> Ash.count!(authorize?: false)
  end

  defp wallets(org) do
    Wallet
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id)
    |> Ash.read!(authorize?: false)
  end

  defp ledger_entries(org) do
    LedgerEntry
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(wallet.organization_id == ^org.id)
    |> Ash.read!(authorize?: false)
  end
end
