defmodule FluxVale.Accounts.Organization.PersonalOwnerBackfillTest do
  @moduledoc """
  Pins the #408 marker backfill — the earliest-owned derivation's last
  home (`PersonalOwnerBackfill.run/0` is the migration's own SQL).

  The rows are built in the PRE-backfill shape. Users ride `Ash.seed!`:
  the User create action JIT-provisions a marked org, and an org-less
  user is a state actions cannot produce (the documented seed!
  exception). Orgs and memberships ride their actions where order
  doesn't matter; ordering-sensitive rows carry forced `created_at` — a
  write-time stamp actions cannot set (members_test's posture).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Accounts.Organization.PersonalOwnerBackfill
  alias FluxVale.Identity.User

  require Ash.Query

  @t0 ~U[2026-01-15 08:00:00.000000Z]

  describe "run/0 (the migration's SQL path)" do
    test "a single owner's earliest-owned org gets marked" do
      user = orgless_user!("solo")
      org = unmarked_org!("solo-org")
      owner_membership!(user, org)

      :ok = PersonalOwnerBackfill.run()

      assert marked_owner(org) == user.id
    end

    test "a later-created owned org stays unmarked — only the earliest-owned is derived" do
      user = orgless_user!("two-orgs")
      earlier = backdated_org!("earlier", @t0)
      later = backdated_org!("later", DateTime.add(@t0, 1, :second))
      owner_membership!(user, earlier)
      owner_membership!(user, later)

      :ok = PersonalOwnerBackfill.run()

      assert marked_owner(earlier) == user.id
      assert marked_owner(later) == nil
    end

    test "the two-owner conflict resolves to the earliest-joining membership" do
      first = orgless_user!("conflict-first")
      second = orgless_user!("conflict-second")
      org = unmarked_org!("contested")

      # One org, the earliest-owned for BOTH users: the seeded two-owner
      # shape. Join times are forced so "earliest" cannot race the clock.
      seeded_membership!(org, first, @t0)
      seeded_membership!(org, second, DateTime.add(@t0, 1, :second))

      :ok = PersonalOwnerBackfill.run()

      assert marked_owner(org) == first.id

      # The loser keeps NO personal org — their PersonalOrgForUser reads
      # :none (the switcher pill degrades to the bare glyph, #308's
      # split-state stance).
      assert :none = Accounts.personal_org_for_user(second.id, authorize?: false)
    end

    test "equal join times break the tie on user_id" do
      one = orgless_user!("tie-one")
      two = orgless_user!("tie-two")
      org = unmarked_org!("tie-org")

      seeded_membership!(org, one, @t0)
      seeded_membership!(org, two, @t0)

      :ok = PersonalOwnerBackfill.run()

      # The SQL orders the tie on user_id; uuid byte order and the
      # string order agree for canonical UUIDv7 text.
      assert marked_owner(org) == Enum.min([one.id, two.id])
    end

    test "a user with no owned org stays unmarked" do
      user = orgless_user!("orgless")

      :ok = PersonalOwnerBackfill.run()

      assert orgs_marked_to(user) == []
    end

    test "re-running over marked rows is a no-op — no raise, no marker moves" do
      # The re-run shape the M6 batched sweep plans for: an
      # already-MARKED user whose earliest-owned org is unmarked, plus
      # an already-marked org another user's derivation points at. The
      # marked org is backdated AND carries its marker — a state no
      # action produces (created_at is a write-time stamp) — so it rides
      # Ash.Seed like the other forced-time rows in this file.
      p = orgless_user!("marked-user")
      q = orgless_user!("challenger")

      earlier = backdated_org!("earlier-of-p", @t0)
      owner_membership!(p, earlier)

      marked =
        Ash.Seed.seed!(Organization, %{
          name: "BF marked",
          slug: "bf-marked-#{System.unique_integer([:positive])}",
          personal_owner_id: p.id,
          created_at: DateTime.add(@t0, 1, :second),
          updated_at: DateTime.add(@t0, 1, :second)
        })

      owner_membership!(p, marked)
      owner_membership!(q, marked)

      # First pass, then the re-run the sweep plans: no raise, and the
      # settled markers stand.
      :ok = PersonalOwnerBackfill.run()
      :ok = PersonalOwnerBackfill.run()

      assert marked_owner(marked) == p.id
      assert marked_owner(earlier) == nil

      assert {:ok, personal} = Accounts.personal_org_for_user(p.id, authorize?: false)
      assert personal.id == marked.id

      # The challenger's derivation points at the marked org — the
      # update guard skips it, so q keeps no personal org.
      assert :none = Accounts.personal_org_for_user(q.id, authorize?: false)
    end
  end

  # Ash.Seed.seed! — the create action JIT-provisions a marked org, and
  # the pre-backfill shape needs an org-less user (state actions cannot
  # produce — the documented seed! exception).
  defp orgless_user!(tag) do
    Ash.Seed.seed!(User, %{email: "#{tag}-#{System.unique_integer([:positive])}@fluxvale.test"})
  end

  # The create action leaves the marker null only when the caller omits
  # it — this shape needs exactly that (pre-backfill org), and no
  # ordering dependency rides it, so the action itself carries the
  # precondition (bootstrap posture, mirrors seeds).
  defp unmarked_org!(tag) do
    n = System.unique_integer([:positive])

    Organization.create!(%{name: "BF #{tag}", slug: "bf-#{tag}-#{n}"}, authorize?: false)
  end

  # Backdated orgs: created_at is a write-time timestamp actions cannot
  # set, and the earliest-owned rule orders on it — seed! territory
  # (members_test's posture). The seed also keeps the marker null.
  defp backdated_org!(tag, created_at) do
    n = System.unique_integer([:positive])

    Ash.Seed.seed!(Organization, %{
      name: "BF #{tag}",
      slug: "bf-#{tag}-#{n}",
      created_at: created_at,
      updated_at: created_at
    })
  end

  # System-only create (#119) — the bootstrap posture, mirroring seeds.
  defp owner_membership!(user, org) do
    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :owner},
      authorize?: false
    )
  end

  # Forced join times: created_at is a write-time timestamp actions
  # cannot set, and the winner rule orders on it — seed! territory
  # (members_test's posture).
  defp seeded_membership!(org, user, created_at) do
    Ash.Seed.seed!(Membership, %{
      organization_id: org.id,
      user_id: user.id,
      role: :owner,
      created_at: created_at,
      updated_at: created_at
    })
  end

  defp marked_owner(org) do
    Organization
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(id == ^org.id)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:personal_owner_id)
  end

  defp orgs_marked_to(user) do
    Organization
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(personal_owner_id == ^user.id)
    |> Ash.read!(authorize?: false)
  end
end
