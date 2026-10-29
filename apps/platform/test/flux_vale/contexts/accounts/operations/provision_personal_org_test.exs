defmodule FluxVale.Accounts.Operations.ProvisionPersonalOrgTest do
  @moduledoc """
  #119's JIT provisioning: User.create auto-creates the personal org with
  the creator as owner (the change delegates here), idempotent on re-login,
  the org named after the username with slug probing on collisions — and
  #122's welcome grant rides the org-creation transaction.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "User.create JIT provisioning" do
    test "fresh signup: org name and slug are the username" do
      user = AccountsFixtures.user!("Terence.A")
      org = AccountsFixtures.personal_org!(user)

      # The handle is the display name and the slug base (owner-approved,
      # #285) — "Terence.A" derives to the slug-valid "terence-a".
      assert user.username == "terence-a"
      assert org.name == user.username
      assert org.slug == user.username
    end

    test "the creator is the org's owner" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      membership = owner_membership(org)

      assert membership.role == :owner
      assert membership.user_id == user.id
    end

    test "re-provisioning is idempotent (re-login never duplicates)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, ^org, false} = Accounts.provision_personal_org(user)
      assert org_count(user) == 1
    end
  end

  describe "slug collisions" do
    test "same local part on different domains: usernames suffix, orgs follow" do
      # The -2/-3 suffixing happens in the username namespace
      # (DeriveUsername); the org name/slug copy the username verbatim.
      # Valid addresses with identical local parts — the mirror (#285 T3)
      # refuses non-deliverable shapes, so `user!/1` would append a second
      # domain; create straight through instead.
      first = User.create!("dup@one.test", %{}, authorize?: false)
      second = User.create!("dup@two.test", %{}, authorize?: false)
      third = User.create!("dup@three.test", %{}, authorize?: false)

      assert AccountsFixtures.personal_org!(first).slug == "dup"
      assert AccountsFixtures.personal_org!(second).slug == "dup-2"
      assert AccountsFixtures.personal_org!(third).slug == "dup-3"

      assert org_count(first) == 1
      assert org_count(second) == 1
      assert org_count(third) == 1
    end

    test "username free but org slug taken: username stays bare, slug gets the suffix" do
      # Precondition via actions, authorize?: false (bootstrap posture —
      # there is no actor; mirrors seeds): an org already owns the slug
      # the new user's handle would take. Username and org-slug are
      # separate namespaces (#285), so only the slug probes past it.
      Organization.create!(%{name: "Squatter", slug: "maya"}, authorize?: false)

      user = AccountsFixtures.user!("maya")
      org = AccountsFixtures.personal_org!(user)

      assert user.username == "maya"
      assert org.name == "maya"
      assert org.slug == "maya-2"
    end

    test "degenerate local parts fall back to the neutral username, org follows" do
      # "+@…" sanitizes to nothing — DeriveUsername's neutral base "user"
      # becomes the username and the org name/slug follow it; a second
      # degenerate signup probes "user-2" in the username namespace.
      first = User.create!("+@degenerate.test", %{}, authorize?: false)
      second = User.create!("+@also-degenerate.test", %{}, authorize?: false)

      assert first.username == "user"
      assert second.username == "user-2"

      first_org = AccountsFixtures.personal_org!(first)
      second_org = AccountsFixtures.personal_org!(second)

      assert first_org.name == "user"
      assert first_org.slug == "user"
      assert second_org.name == "user-2"
      assert second_org.slug == "user-2"
    end

    test "exhausting the probe range falls back to an unguessable suffix" do
      # Occupy "user" (the degenerate username base) and every probed
      # suffix user-2..user-100 — precondition seeding via actions with
      # authorize?: false (no actor, mirrors seeds).
      Enum.each(1..100, fn i ->
        slug = if i == 1, do: "user", else: "user-#{i}"

        Organization.create!(%{name: "occupant #{i}", slug: slug}, authorize?: false)
      end)

      user = User.create!("+@exhausted.test", %{}, authorize?: false)
      org = AccountsFixtures.personal_org!(user)

      assert user.username == "user"

      # The exact fallback shape: base + "-" + 8 lowercase hex chars —
      # a constant straggler like "user-101" must not pass (mirrors the
      # username pin in user_test.exs).
      assert Regex.match?(~r/^user-[0-9a-f]{8}$/, org.slug)
    end
  end

  describe "welcome credits (#122)" do
    test "org creation grants $3 — wallet funded, one welcome ledger entry" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      {:ok, wallet} = Billing.ensure_wallet(org)
      assert {:ok, 300} = Billing.balance(wallet, authorize?: false)

      entries = welcome_entries(wallet)
      assert length(entries) == 1

      entry = hd(entries)
      assert entry.type == :credit
      assert entry.amount == 300
      assert entry.reason == :welcome
    end

    test "re-provisioning never re-fires the grant (once per org, ever)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, ^org, false} = Accounts.provision_personal_org(user)

      {:ok, wallet} = Billing.ensure_wallet(org)
      assert {:ok, 300} = Billing.balance(wallet, authorize?: false)
      assert length(welcome_entries(wallet)) == 1
    end

    test "each org gets its own grant" do
      org_one = AccountsFixtures.personal_org!(AccountsFixtures.user!())
      org_two = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      {:ok, wallet_one} = Billing.ensure_wallet(org_one)
      {:ok, wallet_two} = Billing.ensure_wallet(org_two)

      assert {:ok, 300} = Billing.balance(wallet_one, authorize?: false)
      assert {:ok, 300} = Billing.balance(wallet_two, authorize?: false)
    end
  end

  describe "operator heal of a legacy row (docs/deployment.md rpc)" do
    test "a NULL-username straggler fails with a clear arm, not a Required dump" do
      # Ash.Seed.seed! — the only writer that can produce a NULL-username
      # row (old-pod rolling-window straggler, the rpc's whole audience);
      # the create action derives one (state actions can't produce, the
      # documented seed! exception).
      straggler = Ash.Seed.seed!(User, %{email: "straggler@fluxvale.test"})

      assert {:error, :username_missing} = Accounts.provision_personal_org(straggler)
      assert org_count(straggler) == 0
    end
  end

  defp welcome_entries(wallet) do
    LedgerEntry
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :welcome)
    |> Ash.read!(authorize?: false)
  end

  defp owner_membership(org) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and role == :owner)
    |> Ash.read_one!(authorize?: false)
  end

  defp org_count(user) do
    Organization
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(memberships.user_id == ^user.id)
    |> Ash.count!(authorize?: false)
  end
end
