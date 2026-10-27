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

      assert {:ok, fetched} = Organization.get_by_slug("renamed-org", actor: user)
      assert fetched.id == renamed.id
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

    test "a 40+ char email local part still provisions (the caps bind renames, not signup)" do
      # Round-2 P1 regression: the length caps once sat on the attribute,
      # so the JIT provisioning create failed for a long local part —
      # after the auth code was burned. Signup must not care.
      local_part = String.duplicate("u", 44)
      user = AccountsFixtures.user!(local_part)

      org = AccountsFixtures.personal_org!(user)
      assert org.slug == String.duplicate("u", 44)
    end

    test "a rename to a 40-char slug fails with the field error; 39 fits" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, renamed} =
               Organization.update(org, %{slug: String.duplicate("a", 39)}, actor: user)

      assert {:error, %Invalid{errors: errors}} =
               Organization.update(renamed, %{slug: String.duplicate("b", 40)}, actor: user)

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
    end

    test "a rename caps the name at 100" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, named} =
               Organization.update(org, %{name: String.duplicate("n", 100)}, actor: user)

      assert {:error, %Invalid{errors: errors}} =
               Organization.update(named, %{name: String.duplicate("m", 101)}, actor: user)

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

    test "a legacy >39-char slug can still save a name edit (caps bind changing fields only)" do
      owner = AccountsFixtures.user!()
      legacy_slug = String.duplicate("x", 43)

      # The legacy row predates the cap; the create action carries no
      # length validation (the caps are rename-scoped). Seed via the
      # action with authorize?: false — the bootstrap posture.
      legacy = Organization.create!(%{name: "Legacy", slug: legacy_slug}, authorize?: false)

      # Sanctioned precondition: an owner membership for the policy.
      Membership.create!(%{organization_id: legacy.id, user_id: owner.id, role: :owner},
        authorize?: false
      )

      # The settings form always submits both fields — the untouched slug
      # must not trip the cap.
      assert {:ok, saved} =
               Organization.update(legacy, %{name: "Legacy Renamed", slug: legacy_slug},
                 actor: owner
               )

      assert saved.name == "Legacy Renamed"
      assert saved.slug == legacy_slug
    end

    test "a stale form cannot revert a concurrent name edit (the non-atomic contract)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      # tab2's form: mounted before the concurrent write — its submitted
      # values equal its own stale data.
      stale =
        Ash.Changeset.for_update(org, :update, %{name: org.name, slug: org.slug}, actor: user)

      # tab1 moves the NAME only — the stale form's slug still matches, so
      # this write goes through.
      assert {:ok, _newer} = Organization.update(org, %{name: "Newer Name"}, actor: user)

      # The stale submit succeeds as a no-op write: equal-to-data fields
      # drop out of the SET (a property of the non-atomic action), so the
      # newer name survives. Flipping require_atomic? back on would
      # clobber it — this test fails first.
      assert {:ok, _no_op} = Ash.update(stale)

      assert {:ok, current} = Organization.get_by_slug(org.slug, actor: user)
      assert current.name == "Newer Name"
    end

    test "a changeset mounted before a rename fails stale instead of writing the old slug back" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      # Mount-time changeset: built against the pre-rename row.
      stale = Ash.Changeset.for_update(org, :update, %{name: "Raced Edit"}, actor: user)

      assert {:ok, _moved} = Organization.update(org, %{slug: "moved-first"}, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: errors}} = Ash.update(stale)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      assert {:ok, current} = Organization.get_by_slug("moved-first", actor: user)
      assert current.name == org.name
    end
  end
end
