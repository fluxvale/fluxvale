defmodule FluxVale.Accounts.OrganizationTest do
  @moduledoc """
  Organization resource contract (#119): member-scoped reads, actor-driven
  creates, the slug discipline (format, uniqueness).
  """

  use FluxVale.DataCase, async: true

  alias Ash.Error.Invalid
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
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      # authorize?: false — the system teardown posture (#124 owns the
      # full lifecycle; instances/wallet FKs still guard non-empty orgs)
      assert :ok = Ash.destroy!(org, authorize?: false)

      assert {:error, _gone} = Organization.get_by_id(org.id, authorize?: false)
    end

    test "get_by_slug and get_by_id resolve through the code interface" do
      org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

      assert {:ok, ^org} = Organization.get_by_slug(org.slug, authorize?: false)
      assert {:ok, ^org} = Organization.get_by_id(org.id, authorize?: false)
    end
  end
end
