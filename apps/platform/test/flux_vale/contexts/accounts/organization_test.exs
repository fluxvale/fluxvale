defmodule FluxVale.Accounts.OrganizationTest do
  @moduledoc """
  Organization resource contract (#119): member-scoped reads, actor-driven
  creates, the slug discipline (format, uniqueness).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures

  describe "create" do
    test "any signed-in actor may create an organization" do
      user = AccountsFixtures.user!()

      assert {:ok, org} =
               Organization.create(%{name: "Team Org", slug: "team-org"}, actor: user)

      assert org.name == "Team Org"
    end

    test "anonymous creation is forbidden" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Organization.create(%{name: "Team Org", slug: "team-org"})
    end

    test "slug must be lowercase alphanumeric + hyphens" do
      user = AccountsFixtures.user!()

      for bad <- ["Uppercase", "-leading", "trailing-", "sp ace", "x", "under_score"] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Organization.create(%{name: "Org", slug: bad}, actor: user),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "slugs are unique — the identity is the arbiter" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:error, %Ash.Error.Invalid{}} =
               Organization.create(%{name: "Clone", slug: org.slug}, actor: user)
    end
  end

  describe "reads" do
    test "members read their orgs; strangers see only their own" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, mine} = Ash.read(Organization, actor: user)
      assert Enum.map(mine, & &1.id) == [org.id]

      stranger = AccountsFixtures.user!()

      assert {:ok, theirs} = Ash.read(Organization, actor: stranger)
      refute org.id in Enum.map(theirs, & &1.id)
    end

    test "get_by_slug and get_by_id resolve through the code interface" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      assert {:ok, ^org} = Organization.get_by_slug(org.slug, authorize?: false)
      assert {:ok, ^org} = Organization.get_by_id(org.id, authorize?: false)
    end
  end
end
