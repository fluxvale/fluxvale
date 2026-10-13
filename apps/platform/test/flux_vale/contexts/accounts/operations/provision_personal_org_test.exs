defmodule FluxVale.Accounts.Operations.ProvisionPersonalOrgTest do
  @moduledoc """
  #119's JIT provisioning: User.create auto-creates the personal org with
  the creator as owner (the change delegates here), idempotent on re-login,
  slug probing on local-part collisions.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "User.create JIT provisioning" do
    test "creates the org with the email local part as name, slug-sanitized" do
      user = AccountsFixtures.user!("Terence.A")
      org = AccountsFixtures.personal_org!(user)

      assert org.name == "Terence.A"
      assert org.slug == "terence-a"
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
    test "identical local parts on different domains probe -2, -3…" do
      first = AccountsFixtures.user!("dup@one.test")
      second = AccountsFixtures.user!("dup@two.test")
      third = AccountsFixtures.user!("dup@three.test")

      assert AccountsFixtures.personal_org!(first).slug == "dup"
      assert AccountsFixtures.personal_org!(second).slug == "dup-2"
      assert AccountsFixtures.personal_org!(third).slug == "dup-3"

      assert org_count(first) == 1
      assert org_count(second) == 1
      assert org_count(third) == 1
    end

    test "a pure-symbol local part falls back to the neutral base" do
      # "+@…" sanitizes to an empty slug — the create action's JIT change
      # exercises the fallback through the real path.
      user = User.create!("+@degenerate.test", %{}, authorize?: false)
      org = AccountsFixtures.personal_org!(user)

      assert org.name == "+"
      assert org.slug == "org"
    end

    test "exhausting the probe range falls back to an unguessable suffix" do
      # Occupy "org" (the base) and every probed suffix org-2..org-100.
      Enum.each(1..100, fn i ->
        slug = if i == 1, do: "org", else: "org-#{i}"

        Organization.create!(%{name: "occupant #{i}", slug: slug}, authorize?: false)
      end)

      user = User.create!("+@exhausted.test", %{}, authorize?: false)
      org = AccountsFixtures.personal_org!(user)

      assert String.starts_with?(org.slug, "org-")
      assert org.slug not in ["org", "org-2", "org-100"]
    end
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
