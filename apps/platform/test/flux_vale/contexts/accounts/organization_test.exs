defmodule FluxVale.Accounts.OrganizationTest do
  @moduledoc """
  Organization resource contract (#119): member-scoped reads, actor-driven
  creates, the slug discipline (format, uniqueness).
  """

  use FluxVale.DataCase, async: true

  alias Ash.Error.Invalid
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures

  describe "create" do
    test "creation is system-only (JIT provisioning) — no actor-driven squatting" do
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Organization.create(%{name: "Team Org", slug: "team-org"}, actor: user)

      assert {:error, %Ash.Error.Forbidden{}} =
               Organization.create(%{name: "Team Org", slug: "team-org-2"})
    end

    test "slug must be lowercase alphanumeric + hyphens" do
      # authorize?: false — system posture, mirroring the provisioning flow
      for bad <- ["Uppercase", "-leading", "trailing-", "sp ace", "x", "under_score"] do
        assert {:error, %Invalid{}} =
                 Organization.create(%{name: "Org", slug: bad}, authorize?: false),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "slugs are unique — the identity is the arbiter" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      assert {:error, %Invalid{}} =
               Organization.create(%{name: "Clone", slug: org.slug}, authorize?: false)
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

    test "destroy clears the memberships first (empty-org teardown)" do
      # Bare org, not the JIT path: since #122 every provisioned org
      # carries a welcome-granted wallet, and the wallet FK is the guard
      # under test below.
      org =
        Organization.create!(
          %{name: "teardown", slug: "teardown-#{System.unique_integer([:positive])}"},
          authorize?: false
        )

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id}, authorize?: false)

      # authorize?: false — the system teardown posture (#124 owns the
      # full lifecycle; instances/wallet FKs still guard non-empty orgs)
      assert :ok = Ash.destroy!(org, authorize?: false)

      assert {:error, _gone} = Organization.get_by_id(org.id, authorize?: false)
    end

    test "destroy fails loudly while a wallet exists (billing rows are append-only)" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      # The welcome grant (#122) provisions the wallet; teardown keeping
      # or clearing billing history is #124's design — the FK must hold.
      assert_raise Ash.Error.Unknown, fn -> Ash.destroy!(org, authorize?: false) end

      assert {:ok, _still_here} = Organization.get_by_id(org.id, authorize?: false)
    end

    test "get_by_slug and get_by_id resolve through the code interface" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      assert {:ok, ^org} = Organization.get_by_slug(org.slug, authorize?: false)
      assert {:ok, ^org} = Organization.get_by_id(org.id, authorize?: false)
    end
  end

  describe "update (the rename flow, #276)" do
    test "an owner renames name and slug" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, renamed} =
               Organization.update(org, %{name: "Renamed Org", slug: "renamed-org"}, actor: user)

      assert renamed.name == "Renamed Org"
      assert renamed.slug == "renamed-org"

      assert {:ok, ^renamed} = Organization.get_by_slug("renamed-org", actor: user)
    end

    test "a non-owner member is forbidden — the policy is the authority" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())
      member = AccountsFixtures.user!()

      # Sanctioned precondition: nothing creates :member rows in the
      # system yet, so the row rides the action with authorize?: false.
      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:error, %Ash.Error.Forbidden{}} =
               Organization.update(org, %{name: "Hostile Edit"}, actor: member)
    end

    test "no actor is forbidden" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      assert {:error, %Ash.Error.Forbidden{}} = Organization.update(org, %{name: "X"})
    end

    test "the slug regex holds on update, not just create" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      for bad <- ["Uppercase", "-leading", "trailing-", "sp ace", "x", "under_score"] do
        assert {:error, %Invalid{}} =
                 Organization.update(org, %{slug: bad}, actor: user),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "a same-slug save never self-conflicts (unchanged attributes skip the identity)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, saved} =
               Organization.update(org, %{name: "Name-only edit", slug: org.slug}, actor: user)

      assert saved.slug == org.slug
    end

    test "a rename frees the old slug immediately" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)
      old_slug = org.slug

      assert {:ok, _moved} = Organization.update(org, %{slug: "moved-away"}, actor: user)

      # authorize?: false — system posture (actor-driven create is
      # deliberately closed; the claim proves the old slug is released).
      assert {:ok, _claimed} =
               Organization.create(%{name: "Squatter", slug: old_slug}, authorize?: false)
    end
  end
end
