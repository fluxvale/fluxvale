defmodule FluxVale.Feedback.VoteTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.ActorOrgHasPaid
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Vote
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  # Post precondition through the action, `authorize?: false` — the
  # bootstrap posture (mirrors seeds); the gate arms are the tests'
  # business, and every vote below rides a real actor.
  defp post! do
    Post.create!(
      %{
        title: "Voteable #{System.unique_integer([:positive])}",
        description: "A post worth voting on"
      },
      actor: AccountsFixtures.platform_admin!(),
      authorize?: false
    )
  end

  defp admin, do: AccountsFixtures.platform_admin!()

  defp count!(post), do: Ash.get!(Post, post.id, authorize?: false).vote_count

  # A $1+ purchase on the org's wallet — the ledger shape the paid arm
  # reads (BillingFixtures.mark_paid!).
  defp paid_org!(user) do
    org = AccountsFixtures.owned_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)
    BillingFixtures.mark_paid!(wallet)
    org
  end

  # The operator's paywall waiver — the designated-org path, no money.
  defp waived_user! do
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)

    {:ok, _wallet} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin())

    user
  end

  # The launch arm's precondition: a purpose-:feedback email row for the
  # user's primary address (operator-entered at launch, ADR-0026 §3).
  defp allowlist!(user) do
    AccessRule.create!(%{purpose: :feedback, email: user.email}, authorize?: false)
  end

  describe "the paying gate on cast (ADR-0026 §2/§3)" do
    test "the owner of a paid personal org casts, and the counter follows" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)

      assert {:ok, vote} = Vote.cast(%{post_id: post.id}, actor: user)
      assert vote.organization_id == AccountsFixtures.personal_org!(user).id
      assert vote.cast_by_user_id == user.id
      assert count!(post) == 1
    end

    test "the owner of a paid team org casts for IT — the named org owns the slot" do
      post = post!()
      owner = AccountsFixtures.user!()
      org = paid_org!(owner)

      assert {:ok, vote} = Vote.cast(%{post_id: post.id, organization_id: org.id}, actor: owner)
      assert vote.organization_id == org.id
      assert count!(post) == 1
    end

    test "a mere member of a paid org is Forbidden — the org's vote is the owner's call" do
      post = post!()
      owner = AccountsFixtures.user!()
      org = paid_org!(owner)

      member = AccountsFixtures.user!()

      # System-created precondition (nothing in the system invites yet —
      # the sanctioned bootstrap posture, mirroring seeds).
      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:error, %Ash.Error.Forbidden{}} =
               Vote.cast(%{post_id: post.id, organization_id: org.id}, actor: member)

      assert count!(post) == 0
    end

    test "the owner of a wallet-less org is Forbidden" do
      post = post!()
      {org, owner} = BillingFixtures.grant_free_org!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Vote.cast(%{post_id: post.id, organization_id: org.id}, actor: owner)
    end

    test "a welcome-credit-only org is Forbidden — the signup grant is not a card" do
      post = post!()
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      # The JIT provisioning grant rides along; the ledger holds no
      # purchase — exactly the org the paid arm exists to refuse.
      refute ActorOrgHasPaid.org_paid?(org.id)
      assert {:error, %Ash.Error.Forbidden{}} = Vote.cast(%{post_id: post.id}, actor: user)
    end

    test "a waived org passes — the waiver is the paid arm's other face" do
      post = post!()
      user = waived_user!()

      assert {:ok, _vote} = Vote.cast(%{post_id: post.id}, actor: user)
      assert count!(post) == 1
    end

    test "an allowlisted authed user passes — the launch arm (ADR-0026 §3)" do
      post = post!()
      user = AccountsFixtures.user!()
      allowlist!(user)

      assert {:ok, vote} = Vote.cast(%{post_id: post.id}, actor: user)
      assert vote.organization_id == AccountsFixtures.personal_org!(user).id
    end

    test "an allowlisted user naming an org they do not own is Forbidden — the arm waives the paid test, not ownership" do
      post = post!()
      owner = AccountsFixtures.user!()
      org = paid_org!(owner)

      outsider = AccountsFixtures.user!()
      allowlist!(outsider)

      assert {:error, %Ash.Error.Forbidden{}} =
               Vote.cast(%{post_id: post.id, organization_id: org.id}, actor: outsider)
    end

    test "anonymous is Forbidden — a named org changes nothing for no one" do
      post = post!()
      org = paid_org!(AccountsFixtures.user!())

      assert {:error, %Ash.Error.Forbidden{}} =
               Vote.cast(%{post_id: post.id, organization_id: org.id}, authorize?: true)

      assert count!(post) == 0
    end

    test "a platform admin passes — and may cast for an org they do not own" do
      post = post!()
      org = paid_org!(AccountsFixtures.user!())

      assert {:ok, vote} = Vote.cast(%{post_id: post.id, organization_id: org.id}, actor: admin())
      assert vote.organization_id == org.id
    end
  end

  describe "one vote per org per post" do
    test "a second vote by the same org is rejected by the identity" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)

      assert {:ok, _vote} = Vote.cast(%{post_id: post.id}, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Vote.cast(%{post_id: post.id}, actor: user)

      assert Enum.any?(errors, &(&1.field == :post_id and &1.message == "has already been taken"))

      # The identity failure rolls the whole cast transaction back —
      # the counter's +1 rides the same unit and must not leak.
      assert count!(post) == 1
    end

    test "a second org votes the same post freely" do
      post = post!()
      first = AccountsFixtures.user!()
      second = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(first)
      BillingFixtures.mark_user_paid!(second)

      assert {:ok, _vote} = Vote.cast(%{post_id: post.id}, actor: first)
      assert {:ok, _vote} = Vote.cast(%{post_id: post.id}, actor: second)
      assert count!(post) == 2
    end
  end

  describe "retract" do
    test "decrements the cached count" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)
      {:ok, vote} = Vote.cast(%{post_id: post.id}, actor: user)

      assert :ok = Ash.destroy(vote, actor: user)
      assert count!(post) == 0
    end

    test "frees the slot for another org" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)
      {:ok, vote} = Vote.cast(%{post_id: post.id}, actor: user)

      assert :ok = Ash.destroy(vote, actor: user)

      next = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(next)

      assert {:ok, _vote} = Vote.cast(%{post_id: post.id}, actor: next)
      assert count!(post) == 1
    end

    test "is the org's owner's or an admin's call — no one else's" do
      post = post!()
      owner = AccountsFixtures.user!()
      org = paid_org!(owner)
      {:ok, vote} = Vote.cast(%{post_id: post.id, organization_id: org.id}, actor: owner)

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(vote, actor: member)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(vote, actor: AccountsFixtures.user!())
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(vote, authorize?: true)

      assert :ok = Ash.destroy(vote, actor: admin())
      assert count!(post) == 0
    end

    test "a Forbidden retract leaves the cached count unchanged" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)
      {:ok, vote} = Vote.cast(%{post_id: post.id}, actor: user)
      assert count!(post) == 1

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(vote, actor: AccountsFixtures.user!())

      assert count!(post) == 1
    end
  end

  describe "defaults and failure shapes" do
    test "an unnamed org defaults to the actor's personal org" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)

      assert {:ok, vote} = Vote.cast(%{post_id: post.id}, actor: user)
      assert vote.organization_id == AccountsFixtures.personal_org!(user).id
    end

    test "an orgless actor gets the field-scoped answer, not a crash" do
      post = post!()

      # Ash.Seed.seed! — the only way to produce an org-less user: the
      # create action's JIT change always provisions one (the documented
      # seed! exception).
      orgless =
        Ash.Seed.seed!(FluxVale.Identity.User, %{
          email: "orgless-#{System.unique_integer()}@fluxvale.test"
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Vote.cast(%{post_id: post.id}, actor: orgless)

      assert Enum.any?(errors, &(&1.field == :organization_id and &1.message == "is required"))
    end

    test "anonymous with nothing named is refused with the field-scoped answer — nothing written" do
      post = post!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Vote.cast(%{post_id: post.id}, authorize?: true)

      assert Enum.any?(errors, &(&1.field == :organization_id and &1.message == "is required"))
      assert count!(post) == 0
    end

    test "a dangling post_id is refused field-scoped, nothing written" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Vote.cast(%{post_id: Ash.UUID.generate()}, actor: user)

      assert Enum.any?(
               errors,
               &(&1.field == :post_id and &1.message == "must reference an existing post")
             )

      assert count!(post) == 0
    end

    test "a cast naming no post is refused, nothing written" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)

      # The belongs_to Required error answers an absent post_id at
      # changeset build — before the counter change could.
      assert {:error, %Ash.Error.Invalid{errors: errors}} = Vote.cast(%{}, actor: user)
      assert Enum.any?(errors, &(&1.field == :post_id))

      assert count!(post) == 0
    end

    test "a system caller (no actor, authorize?: false) casts with a nil caster" do
      # The gated action never reaches this shape through policies; this
      # documents the system-caller posture (bootstrap calls run
      # authorize?: false) — the Post.SetActorDefaults mirror.
      post = post!()
      org = paid_org!(AccountsFixtures.user!())

      assert {:ok, vote} =
               Vote.cast(%{post_id: post.id, organization_id: org.id}, authorize?: false)

      assert is_nil(vote.cast_by_user_id)
      assert count!(post) == 1
    end
  end

  describe "post deletion takes its votes (cascade)" do
    test "destroying a post with votes succeeds and the votes are gone" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)
      {:ok, vote} = Vote.cast(%{post_id: post.id}, actor: user)
      assert count!(post) == 1

      # Moderation deletes the post; the votes are its dependent records
      # (on_delete :delete on the FK) — one statement, no count drift,
      # because the counter's row is the post itself.
      assert :ok = Ash.destroy(post, actor: admin())

      assert {:error, _gone} = Ash.get(Vote, vote.id, authorize?: false)

      # Sandbox isolation: this test's only vote rode the destroyed post.
      assert {:ok, []} = Ash.read(Vote)
    end
  end

  describe "reads" do
    test "counts are public data — anonymous reads the rows" do
      post = post!()
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)
      {:ok, _vote} = Vote.cast(%{post_id: post.id}, actor: user)

      assert {:ok, rows} = Ash.read(Vote)
      assert Enum.any?(rows, &(&1.post_id == post.id))
    end
  end
end
