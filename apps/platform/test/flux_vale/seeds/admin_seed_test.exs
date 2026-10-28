defmodule FluxVale.Seeds.AdminSeedTest do
  @moduledoc """
  The promotable seed (`FluxVale.Seeds.seed/0` — dev `mix setup` AND the
  release's `bin/seed` run this path) against a sandboxed DB, so drift
  between helper and resources fails here (#98). Covers the admin-org
  heal (#165) — pre-#119 accounts never got a personal org.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Catalog.Category
  alias FluxVale.Identity.User
  alias FluxVale.Seeds

  require Ash.Query

  describe "seed_admin!/0" do
    test "creates the bootstrap platform admin" do
      :ok = Seeds.seed_admin!()

      assert %{platform_role: :admin} =
               User.get_by_email!("admin@fluxvale.com", authorize?: false)
    end

    test "idempotent — a second run keeps one admin row" do
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin!()

      assert [%User{}] = users_matching_email()
    end

    test "raises on an existing non-admin occupant of the seed email" do
      User.create!("admin@fluxvale.com", %{platform_role: :user}, authorize?: false)

      assert_raise RuntimeError, ~r/non-admin role/, fn ->
        Seeds.seed_admin!()
      end

      # The squatter is untouched — promotion is an operator decision
      assert [%{platform_role: :user}] = users_matching_email()
    end

    defp users_matching_email do
      User
      |> Ash.Query.filter(email == ^"admin@fluxvale.com")
      |> Ash.read!(authorize?: false)
    end
  end

  describe "seed_admin_org!/0" do
    test "heals a pre-#119 admin — exactly one personal org, owner membership" do
      # Ash.Seed.seed! — pre-#119 admins have no org and the User create
      # action now always provisions one (state actions can't produce,
      # the documented seed! exception). The username rides along: the
      # #285 backfill gave every legacy row one, so provisioning has a
      # handle to name the org after (a bare row is unreachable state).
      Ash.Seed.seed!(User, %{
        email: "admin@fluxvale.com",
        platform_role: :admin,
        username: "admin"
      })

      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin_org!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      assert org_count(admin.id) == 1

      [membership] = memberships(personal_org!(admin.id).id)
      assert membership.role == :owner
      assert membership.user_id == admin.id
    end

    test "idempotent — a second run adds no org and no second ledger entry" do
      Ash.Seed.seed!(User, %{
        email: "admin@fluxvale.com",
        platform_role: :admin,
        username: "admin"
      })

      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin_org!()
      :ok = Seeds.seed_admin_org!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      org = personal_org!(admin.id)

      assert org_count(admin.id) == 1

      {:ok, wallet} = Billing.ensure_wallet(org)
      assert {:ok, 300} = Billing.balance(wallet, authorize?: false)
      assert length(welcome_entries(wallet)) == 1
    end

    test "an admin that already has an org is untouched" do
      # seed_admin! creates through the User create action, whose JIT
      # change already provisions the org — seed_admin_org! must no-op.
      :ok = Seeds.seed_admin!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      org_before = personal_org!(admin.id)

      :ok = Seeds.seed_admin_org!()

      assert personal_org!(admin.id).id == org_before.id
      assert org_count(admin.id) == 1

      {:ok, wallet} = Billing.ensure_wallet(org_before)
      assert length(welcome_entries(wallet)) == 1
    end

    test "the welcome grant is 300 cents with reason :welcome" do
      Ash.Seed.seed!(User, %{
        email: "admin@fluxvale.com",
        platform_role: :admin,
        username: "admin"
      })

      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin_org!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      org = personal_org!(admin.id)
      {:ok, wallet} = Billing.ensure_wallet(org)

      [entry] = welcome_entries(wallet)
      assert entry.type == :credit
      assert entry.amount == 300
      assert entry.reason == :welcome
    end

    defp personal_org!(user_id) do
      {:ok, org} = Accounts.personal_org_for_user(user_id, authorize?: false)
      org
    end

    defp org_count(user_id) do
      Organization
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(memberships.user_id == ^user_id and memberships.role == :owner)
      |> Ash.count!(authorize?: false)
    end

    defp memberships(org_id) do
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(organization_id == ^org_id)
      |> Ash.read!(authorize?: false)
    end

    defp welcome_entries(wallet) do
      LedgerEntry
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :welcome)
      |> Ash.read!(authorize?: false)
    end
  end

  describe "seed/0" do
    test "runs admin + catalog — the promotable path, no local-cluster row" do
      :ok = Seeds.seed()

      assert User.get_by_email!("admin@fluxvale.com", authorize?: false)
      # Catalog converged (#70's machinery; Forgejo + Kavita ship in the
      # YAML). Asserted by slug, not row count — the catalog grows.
      assert {:ok, _forgejo} = Category.get_by_slug("developer-tools", authorize?: false)

      assert {:ok, _kavita} = Category.get_by_slug("media", authorize?: false)
    end

    test "heals a pre-#119 admin through the promotable path" do
      # Delegation guard: the heal rides seed/0 itself — dropping
      # seed_admin_org!/0 from it must fail here, not in prod bring-up.
      Ash.Seed.seed!(User, %{
        email: "admin@fluxvale.com",
        platform_role: :admin,
        username: "admin"
      })

      :ok = Seeds.seed()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)

      assert 1 ==
               Organization
               |> Ash.Query.for_read(:read, %{})
               |> Ash.Query.filter(
                 memberships.user_id == ^admin.id and memberships.role == :owner
               )
               |> Ash.count!(authorize?: false)

      {:ok, org} = Accounts.personal_org_for_user(admin.id, authorize?: false)
      {:ok, wallet} = Billing.ensure_wallet(org)

      welcome =
        LedgerEntry
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :welcome)
        |> Ash.read!(authorize?: false)

      assert length(welcome) == 1
    end
  end
end
