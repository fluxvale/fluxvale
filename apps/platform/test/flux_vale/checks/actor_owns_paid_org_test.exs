defmodule FluxVale.Checks.ActorOwnsPaidOrgTest do
  @moduledoc false

  # The feedback-board write gate: owner of the org in play AND past the
  # paid gate — or the launch allowlist (:feedback AccessRule rows), or a
  # platform admin. These tests pin the check's own resolution and arms;
  # the action-level arms live in the Vote/Post suites.

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Checks.ActorOwnsPaidOrg
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Vote
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  describe "describe/1" do
    test "names the gate" do
      assert ActorOwnsPaidOrg.describe([]) ==
               "the actor owns the org in play and it has paid (or the launch allowlist / an admin passes)"
    end
  end

  describe "board_write_allowed?/2 (the public predicate)" do
    test "the owner of a paid org passes" do
      user = AccountsFixtures.user!()
      org = BillingFixtures.mark_user_paid!(user)

      assert ActorOwnsPaidOrg.board_write_allowed?(user, org.id)
    end

    test "the owner of an unpaid org does not" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      refute ActorOwnsPaidOrg.board_write_allowed?(user, org.id)
    end

    test "the owner of an unpaid org passes under the launch arm — a :feedback row waives the paid test, not ownership" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)
      AccessRule.create!(%{purpose: :feedback, email: user.email}, authorize?: false)

      assert ActorOwnsPaidOrg.board_write_allowed?(user, org.id)
    end

    test "a mere member of a paid org does not — the slot is the owner's call" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      {:ok, wallet} = Billing.ensure_wallet(org)
      BillingFixtures.mark_paid!(wallet)

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      refute ActorOwnsPaidOrg.board_write_allowed?(member, org.id)
    end

    test "a platform admin passes — and anonymous does not" do
      org = BillingFixtures.mark_user_paid!(AccountsFixtures.user!())
      admin = admin()

      assert ActorOwnsPaidOrg.board_write_allowed?(admin, org.id)
      refute ActorOwnsPaidOrg.board_write_allowed?(nil, org.id)
    end

    test "an unresolved org fails closed" do
      user = BillingFixtures.mark_user_paid!(AccountsFixtures.user!())

      refute ActorOwnsPaidOrg.board_write_allowed?(user, nil)
    end

    test "an owner whose primary email cannot resolve fails closed — even with a :feedback row for their address" do
      # Ash.Seed.seed! — the only way to produce a user with no
      # user_emails rows: the create action mirrors the signup address as
      # a VERIFIED PRIMARY row (the documented seed! exception). The
      # launch arm reads the PRIMARY email; nothing resolves → nobody.
      orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})
      org = AccountsFixtures.owned_org!(orgless)

      AccessRule.create!(%{purpose: :feedback, email: orgless.email}, authorize?: false)

      refute ActorOwnsPaidOrg.board_write_allowed?(orgless, org.id)
    end
  end

  describe "match?/3 — the subject's org resolution" do
    test "a create answers the org the write NAMES via the argument" do
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)
      team = AccountsFixtures.owned_org!(user)

      subject =
        Ash.Changeset.for_create(Vote, :cast, %{organization_id: team.id}, authorize?: false)

      # Team org unpaid: the named org answers (not the paid personal one).
      refute ActorOwnsPaidOrg.match?(user, %{subject: subject}, [])

      {:ok, wallet} = Billing.ensure_wallet(team)
      BillingFixtures.mark_paid!(wallet)

      assert ActorOwnsPaidOrg.match?(user, %{subject: subject}, [])
    end

    test "a create answers the org the write NAMES via the attribute — both intake shapes" do
      user = AccountsFixtures.user!()
      org = BillingFixtures.mark_user_paid!(user)
      changeset = Ash.Changeset.for_create(Vote, :cast, %{}, authorize?: false)

      subject = Ash.Changeset.force_change_attribute(changeset, :organization_id, org.id)

      assert ActorOwnsPaidOrg.match?(user, %{subject: subject}, [])
    end

    test "a create naming nothing answers the actor's personal org" do
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)

      subject = Ash.Changeset.for_create(Vote, :cast, %{}, authorize?: false)

      assert ActorOwnsPaidOrg.match?(user, %{subject: subject}, [])
    end

    test "a create naming nothing with an org-less actor fails closed" do
      # Ash.Seed.seed! — see the primary-email test above (the documented
      # seed! exception).
      orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})

      subject = Ash.Changeset.for_create(Vote, :cast, %{}, authorize?: false)

      refute ActorOwnsPaidOrg.match?(orgless, %{subject: subject}, [])
    end

    test "an anonymous actor's unnamed create fails closed" do
      subject = Ash.Changeset.for_create(Vote, :cast, %{}, authorize?: false)

      refute ActorOwnsPaidOrg.match?(nil, %{subject: subject}, [])
    end

    test "a destroy answers the ROW's org, freshly read" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)
      {:ok, wallet} = Billing.ensure_wallet(org)
      BillingFixtures.mark_paid!(wallet)

      post =
        Post.create!(%{title: "Row resolution post", description: "x"},
          actor: AccountsFixtures.platform_admin!(),
          authorize?: false
        )

      {:ok, vote} =
        Vote.cast(%{post_id: post.id, organization_id: org.id}, actor: owner)

      subject = Ash.Changeset.for_destroy(vote, :retract, %{}, authorize?: false)

      assert ActorOwnsPaidOrg.match?(owner, %{subject: subject}, [])
      refute ActorOwnsPaidOrg.match?(AccountsFixtures.user!(), %{subject: subject}, [])
    end

    test "a tampered REAL row still answers on the fresh row's org" do
      # The changeset claims an org the actor OWNS and has PAID — under
      # a trust-the-changeset regression this actor passes both arms —
      # while the fresh row's org is a stranger's. The gate must not
      # care what the struct claims: a destroy re-reads the ROW, and
      # the fresh row's org is what answers (pins
      # reload-doesn't-trust-the-struct against future refactors).
      caster = AccountsFixtures.user!()
      caster_org = BillingFixtures.mark_user_paid!(caster)

      post =
        Post.create!(%{title: "Tamper probe post", description: "x"},
          actor: AccountsFixtures.platform_admin!(),
          authorize?: false
        )

      {:ok, vote} = Vote.cast(%{post_id: post.id, organization_id: caster_org.id}, actor: caster)

      tamperer_user = AccountsFixtures.user!()
      tamperer_org = BillingFixtures.mark_user_paid!(tamperer_user)
      changeset = Ash.Changeset.for_destroy(vote, :retract, %{}, actor: tamperer_user)

      tampered =
        Ash.Changeset.force_change_attribute(changeset, :organization_id, tamperer_org.id)

      refute ActorOwnsPaidOrg.match?(tamperer_user, %{subject: tampered}, [])
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(tampered)

      # The refused tamper broke nothing real: the honest retract works.
      assert :ok = Ash.destroy(vote, actor: caster)
    end

    test "a struct naming no row fails closed — the gate must not trust caller-controlled data" do
      org = BillingFixtures.mark_user_paid!(AccountsFixtures.user!())

      phantom = %Vote{id: Ecto.UUID.generate(), organization_id: org.id}
      subject = Ash.Changeset.for_destroy(phantom, :retract, %{}, authorize?: false)

      refute ActorOwnsPaidOrg.match?(nil, %{subject: subject}, [])
    end

    test "an atomic changeset's placeholder data fails closed without raising" do
      org = BillingFixtures.mark_user_paid!(AccountsFixtures.user!())

      changeset =
        Ash.Changeset.for_destroy(
          %Vote{id: Ecto.UUID.generate(), organization_id: org.id},
          :retract,
          %{},
          authorize?: false
        )

      atomic = %{changeset | data: %Ash.Changeset.OriginalDataNotAvailable{}}

      refute ActorOwnsPaidOrg.match?(nil, %{subject: atomic}, [])
    end

    test "a non-changeset subject fails closed — even for a paid actor" do
      user = BillingFixtures.mark_user_paid!(AccountsFixtures.user!())

      refute ActorOwnsPaidOrg.match?(user, %{subject: %Vote{}}, [])
    end
  end

  defp admin, do: AccountsFixtures.platform_admin!()
end
