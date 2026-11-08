defmodule FluxVale.Feedback.PostTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Post.AuthorStatusMail
  alias FluxVale.Feedback.Post.DeriveSlug
  alias FluxVale.Feedback.Post.RejectReferencedOriginal
  alias FluxVale.Feedback.Post.SetActorDefaults
  alias FluxVale.Feedback.Post.SetStatus
  alias FluxVale.Feedback.Vote.BumpPostVoteCount
  alias FluxVale.Feedback.Vote.SetCastDefaults
  alias FluxVale.Ops.AccessRule
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures

  # Precondition posture (mirrors seeds): fixtures run `authorize?: false`;
  # the policy arms under test are exercised in the test bodies. The actor
  # still rides along — create derives org + creator from it, so a
  # fixture cannot skip that part of the contract.
  defp post!(attrs \\ %{}) do
    defaults = %{
      title: "Fixture post #{System.unique_integer([:positive])}",
      description: "A fixture post"
    }

    params = Map.merge(defaults, attrs)
    Post.create!(params, actor: admin(), authorize?: false)
  end

  defp admin, do: AccountsFixtures.platform_admin!()
  defp regular, do: AccountsFixtures.user!()

  describe "policies — reads" do
    test "an anonymous visitor reads the board" do
      post!(%{title: "Readable by anyone", description: "The board is public"})

      assert {:ok, rows} = Ash.read(Post)
      assert Enum.any?(rows, &(&1.title == "Readable by anyone"))
    end

    test "any signed-in actor reads the board" do
      post!(%{title: "Readable by users", description: "The board is public"})

      assert {:ok, rows} = Ash.read(Post, actor: regular())
      assert Enum.any?(rows, &(&1.title == "Readable by users"))
    end
  end

  describe "policies — writes" do
    test "a no-actor create is refused with the field-scoped answer, not Forbidden" do
      # Ash 3 runs create policies after changes/validations, so the
      # `present(:organization_id)` validation answers before the admin
      # gate could (the Instance create's documented shape) — nothing is
      # written either way.
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.create(%{title: "No actor here", description: "Refused"}, authorize?: true)

      assert Enum.any?(
               errors,
               &(&1.field == :organization_id and &1.message == "is required")
             )
    end

    test "a non-admin create is Forbidden" do
      assert {:error, %Ash.Error.Forbidden{}} =
               Post.create(
                 %{title: "Not an admin", description: "Refused"},
                 actor: regular()
               )
    end

    test "an admin creates a post, born open with zero counters and actor defaults" do
      admin = admin()

      assert {:ok, post} =
               Post.create(
                 %{title: "Dark mode for the dashboard", description: "Please."},
                 actor: admin
               )

      assert post.status == :open
      assert post.vote_count == 0
      assert post.comment_count == 0
      assert post.created_by_user_id == admin.id
      assert post.organization_id == AccountsFixtures.personal_org!(admin).id
    end

    test "an actor with no org gets the field-scoped answer (loud, not a crash)" do
      # Ash.seed! — the only way to produce an org-less user: the create
      # action's JIT change always provisions one (state actions can't
      # produce, the documented seed! exception).
      orgless =
        Ash.Seed.seed!(FluxVale.Identity.User, %{
          username: username_seed_for("orgless-#{System.unique_integer()}@fluxvale.test")
        })

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.create(%{title: "No org to post from", description: "Refused"},
                 actor: orgless
               )

      assert Enum.any?(errors, &(&1.field == :organization_id and &1.message == "is required"))
    end

    test "generic update and destroy are admin-only" do
      post = post!()
      regular = regular()

      assert {:error, %Ash.Error.Forbidden{}} =
               Post.update(post, %{title: "Edited by a non-admin"}, actor: regular)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(post, actor: regular)

      assert {:ok, edited} =
               Post.update(post, %{title: "Edited by an admin"}, actor: admin())

      assert edited.title == "Edited by an admin"
    end
  end

  describe "the paying gate on create (ADR-0026 §2/§3, slice 2)" do
    test "a paid personal org's owner creates — no admin in the loop" do
      user = AccountsFixtures.user!()
      BillingFixtures.mark_user_paid!(user)

      assert {:ok, post} =
               Post.create(%{title: "Owner-filed request", description: "Please."},
                 actor: user
               )

      assert post.organization_id == AccountsFixtures.personal_org!(user).id
    end

    test "the owner names their paid team org and the post rides it" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
      BillingFixtures.mark_paid!(wallet)

      assert {:ok, post} =
               Post.create(
                 %{
                   title: "Team-filed request",
                   description: "For the org.",
                   organization_id: org.id
                 },
                 actor: owner
               )

      assert post.organization_id == org.id
    end

    test "a mere member naming the paid org is Forbidden" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
      BillingFixtures.mark_paid!(wallet)

      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:error, %Ash.Error.Forbidden{}} =
               Post.create(
                 %{
                   title: "Member-filed request",
                   description: "Refused.",
                   organization_id: org.id
                 },
                 actor: member
               )
    end

    test "an unpaid owner is Forbidden (the old admin-only refusal shape keeps its non-payers)" do
      user = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Post.create(%{title: "Unpaid owner request", description: "Refused."}, actor: user)
    end

    test "an allowlisted unpaid owner creates — the launch arm opens the gate" do
      user = AccountsFixtures.user!()

      AccessRule.create!(%{purpose: :feedback, email: AccountsFixtures.primary_address!(user)},
        authorize?: false
      )

      assert {:ok, post} =
               Post.create(%{title: "Invited cohort request", description: "At launch."},
                 actor: user
               )

      assert post.organization_id == AccountsFixtures.personal_org!(user).id
    end

    test "an admin passes everything — including naming an org they do not own" do
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:ok, post} =
               Post.create(
                 %{
                   title: "Admin-filed request",
                   description: "Moderation.",
                   organization_id: org.id
                 },
                 actor: admin()
               )

      assert post.organization_id == org.id
    end

    test "anonymous naming an org answers Forbidden — the gate, not a field error" do
      # The named org is pinned even without an actor (SetActorDefaults),
      # so the changeset is valid and the write gate answers. A field
      # error here would mean the gate never saw the write.
      owner = AccountsFixtures.user!()
      org = AccountsFixtures.owned_org!(owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Post.create(
                 %{
                   title: "Anonymous request",
                   description: "Refused.",
                   organization_id: org.id
                 },
                 authorize?: true
               )
    end

    test "a system caller (no actor, authorize?: false) bootstraps a post for a named org" do
      org = AccountsFixtures.owned_org!(AccountsFixtures.user!())

      assert {:ok, post} =
               Post.create(
                 %{
                   title: "System bootstrap post",
                   description: "Seeded.",
                   organization_id: org.id
                 },
                 authorize?: false
               )

      assert post.organization_id == org.id
      assert is_nil(post.created_by_user_id)
    end
  end

  describe "set_status" do
    test "it is admin-only" do
      post = post!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Post.set_status(post, %{status: :planned}, actor: regular())

      admin = admin()

      assert {:ok, moved} = Post.set_status(post, %{status: :planned}, actor: admin)
      assert moved.status == :planned
      assert moved.status_changed_by_user_id == admin.id
      assert %DateTime{} = moved.status_changed_at
    end

    test "to :duplicate requires the original post" do
      post = post!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.set_status(post, %{status: :duplicate}, actor: admin())

      assert Enum.any?(errors, &(&1.field == :duplicate_of_id))
    end

    test "to :duplicate rejects self-reference" do
      post = post!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.set_status(post, %{status: :duplicate, duplicate_of_id: post.id},
                 actor: admin()
               )

      assert Enum.any?(errors, &(&1.field == :duplicate_of_id))
    end

    test "to :duplicate with an original points at it and stamps the audit trail" do
      original = post!(%{title: "The Original", description: "x"})
      dup = post!(%{title: "The Duplicate", description: "x"})
      admin = admin()

      assert {:ok, moved} =
               Post.set_status(dup, %{status: :duplicate, duplicate_of_id: original.id},
                 actor: admin
               )

      assert moved.status == :duplicate
      assert moved.duplicate_of_id == original.id
      assert moved.status_changed_by_user_id == admin.id
      assert %DateTime{} = moved.status_changed_at
    end

    test "an off-duplicate move clears a stale pointer" do
      original = post!(%{title: "Original Again", description: "x"})
      dup = post!(%{title: "Dup Again", description: "x"})
      admin = admin()

      assert {:ok, _moved} =
               Post.set_status(dup, %{status: :duplicate, duplicate_of_id: original.id},
                 actor: admin
               )

      assert {:ok, moved} = Post.set_status(dup, %{status: :planned}, actor: admin)
      assert moved.status == :planned
      assert is_nil(moved.duplicate_of_id)
    end

    test "an off-duplicate move cannot plant a pointer" do
      original = post!(%{title: "Unrelated Original", description: "x"})
      post = post!(%{title: "Never A Duplicate", description: "x"})
      admin = admin()

      assert {:ok, moved} =
               Post.set_status(post, %{status: :planned, duplicate_of_id: original.id},
                 actor: admin
               )

      assert moved.status == :planned
      assert is_nil(moved.duplicate_of_id)
    end

    test "a duplicate may not point at a duplicate (depth one, no chains)" do
      original = post!(%{title: "Chain Original", description: "x"})
      dup = post!(%{title: "Chain Dup", description: "x"})
      admin = admin()

      assert {:ok, _moved} =
               Post.set_status(dup, %{status: :duplicate, duplicate_of_id: original.id},
                 actor: admin
               )

      other = post!(%{title: "Chain Other", description: "x"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.set_status(other, %{status: :duplicate, duplicate_of_id: dup.id},
                 actor: admin
               )

      assert Enum.any?(
               errors,
               &(&1.field == :duplicate_of_id and
                   &1.message == "cannot reference a post that is itself a duplicate")
             )
    end

    test "a pointer at a missing post fails closed" do
      post = post!(%{title: "Dangling Target", description: "x"})

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.set_status(post, %{status: :duplicate, duplicate_of_id: Ash.UUID.generate()},
                 actor: admin()
               )

      assert Enum.any?(
               errors,
               &(&1.field == :duplicate_of_id and
                   &1.message == "must reference an existing post that is not a duplicate")
             )
    end

    test "re-asserting :duplicate without re-passing the pointer stays idempotent" do
      original = post!(%{title: "Idempotent Original", description: "x"})
      dup = post!(%{title: "Idempotent Dup", description: "x"})
      admin = admin()

      assert {:ok, moved} =
               Post.set_status(dup, %{status: :duplicate, duplicate_of_id: original.id},
                 actor: admin
               )

      # The pointer rides get_attribute's data fallback (documented in
      # SetStatus): the reload carries the current row's pointer, so the
      # bare re-assertion keeps pointing at the same original.
      assert {:ok, reloaded} = Ash.get(Post, moved.id, authorize?: false)

      assert {:ok, reasserted} = Post.set_status(reloaded, %{status: :duplicate}, actor: admin)
      assert reasserted.status == :duplicate
      assert reasserted.duplicate_of_id == original.id
    end

    test "the status argument accepts declared atoms only" do
      post = post!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.set_status(post, %{status: :bogus}, actor: admin())

      assert Enum.any?(
               errors,
               &(&1.field == :status and
                   &1.message == "atom must be one of %{atom_list}, got: %{value}")
             )
    end

    test "a system caller (no actor, authorize?: false) stamps a nil author" do
      # The admin-gated action never reaches this shape through policies;
      # this documents the system-caller posture (bootstrap calls run
      # authorize?: false).
      post = post!()

      assert {:ok, moved} = Post.set_status(post, %{status: :declined}, authorize?: false)
      assert moved.status == :declined
      assert is_nil(moved.status_changed_by_user_id)
      assert %DateTime{} = moved.status_changed_at
    end
  end

  describe "destroy" do
    test "an unreferenced post destroys" do
      post = post!(%{title: "Doomed Post", description: "x"})

      assert :ok = Ash.destroy(post, actor: admin())

      assert {:error, _not_found} = Ash.get(Post, post.id, authorize?: false)
    end

    test "destroying an original a duplicate points at is refused field-scoped" do
      original = post!(%{title: "Referenced Original", description: "x"})
      dup = post!(%{title: "Pointing Dup", description: "x"})
      admin = admin()

      assert {:ok, _moved} =
               Post.set_status(dup, %{status: :duplicate, duplicate_of_id: original.id},
                 actor: admin
               )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.destroy(original, actor: admin)

      assert Enum.any?(
               errors,
               &(&1.field == :duplicate_of_id and
                   &1.message == "is pointed at by a duplicate post")
             )

      assert {:ok, _still_there} = Ash.get(Post, original.id, authorize?: false)
    end
  end

  describe "slug" do
    test "derived from a messy title" do
      assert {:ok, post} =
               Post.create(
                 %{title: "  Bug: Import fails -- 100% CPU!!  ", description: "It eats cores"},
                 actor: admin(),
                 authorize?: false
               )

      assert post.slug == "bug-import-fails-100-cpu"
    end

    test "collisions append a numeric suffix" do
      {:ok, first} =
        Post.create(%{title: "Same Title Here", description: "one"},
          actor: admin(),
          authorize?: false
        )

      {:ok, second} =
        Post.create(%{title: "Same Title Here", description: "two"},
          actor: admin(),
          authorize?: false
        )

      {:ok, third} =
        Post.create(%{title: "Same   Title -- HERE!!!", description: "three"},
          actor: admin(),
          authorize?: false
        )

      assert first.slug == "same-title-here"
      assert second.slug == "same-title-here-2"
      assert third.slug == "same-title-here-3"
    end

    test "stable across renames (slug is set at create only)" do
      {:ok, post} =
        Post.create(%{title: "Original Title", description: "x"},
          actor: admin(),
          authorize?: false
        )

      assert {:ok, renamed} = Post.update(post, %{title: "Brand New Title"}, authorize?: false)
      assert renamed.title == "Brand New Title"
      assert renamed.slug == "original-title"
    end

    test "a changeset already carrying a slug keeps it (derivation is not a clobberer)" do
      changeset =
        Post
        |> Ash.Changeset.for_create(:create, %{title: "Pinned Title", description: "x"},
          actor: admin(),
          authorize?: false
        )
        |> Ash.Changeset.force_change_attribute(:slug, "pinned-slug")

      assert {:ok, post} = Ash.create(changeset)
      assert post.slug == "pinned-slug"
    end

    test "a title with no slug-able characters falls back to the neutral base" do
      assert {:ok, post} =
               Post.create(
                 %{title: "----", description: "Punctuation only, four chars"},
                 actor: admin(),
                 authorize?: false
               )

      assert post.slug == "post"
    end

    test "the suffix eats into the base's budget so the slug stays within 140" do
      long_title = String.duplicate("a", 140)

      {:ok, first} =
        Post.create(%{title: long_title, description: "one"}, actor: admin(), authorize?: false)

      assert String.length(first.slug) == 140

      {:ok, second} =
        Post.create(%{title: long_title, description: "two"}, actor: admin(), authorize?: false)

      assert String.length(second.slug) == 140
      assert String.ends_with?(second.slug, "-2")
      assert second.slug != first.slug
    end

    test "a reserved stem is not claimable" do
      # "NEW!" sanitizes to the reserved stem "new"; the probe must walk
      # past it to the first free candidate.
      assert {:ok, post} =
               Post.create(%{title: "NEW!", description: "The reserved stem"},
                 actor: admin(),
                 authorize?: false
               )

      assert post.slug == "new-2"
    end

    test "a title that expands past the budget under downcase stays within 140" do
      # U+0130 (capital I with dot above) downcases to TWO graphemes
      # (i + combining dot): this title is 140 graphemes at the cast and
      # expands past 200 mid-pipeline. The truncation must land the slug
      # inside the 140 contract and keep it URL-shaped.
      title = String.duplicate("İx", 70)

      assert {:ok, post} =
               Post.create(%{title: title, description: "Expansion"},
                 actor: admin(),
                 authorize?: false
               )

      assert String.length(post.slug) <= 140

      assert Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, post.slug)
    end

    test "probe exhaustion falls back to an unguessable suffix" do
      # The free? probe is injected: every candidate "taken" drives the
      # bounded probe range to exhaustion without 100 colliding rows.
      slug = DeriveSlug.derive_unique("Exhausted Title", fn _candidate -> false end)

      assert String.starts_with?(slug, "exhausted-title-")
      assert Regex.match?(~r/-[0-9a-f]{8}$/, slug)
    end
  end

  describe "constraints" do
    test "title bounds and the description cap answer at the cast, field-pinned" do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.create(%{title: "abc", description: "Under the 4-char floor"},
                 actor: admin(),
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :title and
                   &1.message == "length must be greater than or equal to %{min}")
             )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.create(%{title: String.duplicate("x", 141), description: "Over the ceiling"},
                 actor: admin(),
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :title and
                   &1.message == "length must be less than or equal to %{max}")
             )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.create(%{title: "Valid title", description: String.duplicate("x", 5001)},
                 actor: admin(),
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :description and
                   &1.message == "length must be less than or equal to %{max}")
             )
    end

    test "the title cap counts codepoints, so a combining-mark title one grapheme over fails" do
      # The :codepoints flip (CVE-2026-82752, hostile review fix round):
      # each "a" + combining-acute pair is one grapheme and TWO codepoints.
      # 70 pairs sit exactly on the 140 cap (codepoints count inclusively),
      # and one more pair is 71 graphemes but 142 codepoints. The 71-pair
      # title passed the old grapheme count and must fail now.
      at_cap = String.duplicate("a" <> "\u0301", 70)
      over_cap = String.duplicate("a" <> "\u0301", 71)

      assert {:ok, _post} =
               Post.create(%{title: at_cap, description: "Exactly at the cap"},
                 actor: admin(),
                 authorize?: false
               )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Post.create(%{title: over_cap, description: "One grapheme over the cap"},
                 actor: admin(),
                 authorize?: false
               )

      assert Enum.any?(
               errors,
               &(&1.field == :title and
                   &1.message == "length must be less than or equal to %{max}")
             )
    end
  end

  describe "change declarations" do
    test "the function changes declare non-atomic (their actions carry require_atomic? false)" do
      refute DeriveSlug.atomic?()
      refute SetActorDefaults.atomic?()
      refute SetStatus.atomic?()
      refute AuthorStatusMail.atomic?()
      refute RejectReferencedOriginal.atomic?()
      refute SetCastDefaults.atomic?()
      refute BumpPostVoteCount.atomic?()
    end
  end

  # #287: seed! companions need the handle explicitly (NOT NULL); the
  # local part of the original address is unique per call.
  defp username_seed_for(address) do
    [local | _rest] = String.split(address, "@", parts: 2)

    local
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
  end
end
