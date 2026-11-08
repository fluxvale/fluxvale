defmodule FluxVale.Accounts.MembershipInviteTest do
  @moduledoc """
  The MembershipInvite contract (slice 4 of #408): the row stores the
  token's sha256 (never the raw), `:member` is the only role any
  caller can produce, the open-invite uniqueness is arbitrated by the
  partial index, accept is single-fire and joins in one transaction,
  and the state axis answers open/accepted/revoked/expired. Policies:
  org members read, owners write, the token actions forbid every actor
  path.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.MembershipInvite
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "create contract" do
    test "stores the sha256 of the raw token — never the raw value" do
      {org, _owner} = owned_org!()
      raw = "raw-token-value-never-stored-abc123xyz"

      invite =
        create_invite!(%{
          organization_id: org.id,
          email: "invitee@fluxvale.test",
          token_hash: MembershipInvite.token_hash(raw)
        })

      assert invite.token_hash == MembershipInvite.token_hash(raw)
      refute invite.token_hash == raw
      # SHA-256 hex digest: 64 lowercase hex characters.
      assert invite.token_hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "role is not accepted — every create writes :member" do
      {org, _owner} = owned_org!()

      # The role is not in the accept list — a caller cannot mint an
      # owner grant through the create.
      assert {:error, %Ash.Error.Invalid{}} =
               create_invite(%{
                 organization_id: org.id,
                 email: "cant-self-promote@fluxvale.test",
                 role: :owner
               })

      invite = create_invite!(%{organization_id: org.id, email: "member-default@fluxvale.test"})
      assert invite.role == :member
    end

    test "expires_at defaults to the 7-day window" do
      {org, _owner} = owned_org!()

      invite = create_invite!(%{organization_id: org.id, email: "window@fluxvale.test"})

      assert DateTime.compare(invite.expires_at, DateTime.utc_now()) == :gt

      assert DateTime.diff(invite.expires_at, DateTime.utc_now(), :second) in 0..(MembershipInvite.ttl_days() *
                                                                                    24 * 60 * 60)
    end

    test "one OPEN invite per (org, email) — the second create fails on the partial index" do
      {org, _owner} = owned_org!()

      create_invite!(%{organization_id: org.id, email: "dup@fluxvale.test"})

      assert {:error, _taken} =
               create_invite(%{organization_id: org.id, email: "dup@fluxvale.test"})
    end

    test "citext equality: a case-variant address hits the same open-invite uniqueness" do
      {org, _owner} = owned_org!()

      create_invite!(%{organization_id: org.id, email: "Folded@fluxvale.test"})

      assert {:error, _taken} =
               create_invite(%{organization_id: org.id, email: "folded@FLUXVALE.TEST"})
    end

    test "an accepted row no longer blocks the address" do
      {org, _owner} = owned_org!()
      invitee = AccountsFixtures.user!()

      invite = invite_for!(org, AccountsFixtures.primary_address!(invitee))
      accepted = accept!(invite, invitee.id)

      assert {:ok, _fresh} =
               create_invite(%{
                 organization_id: org.id,
                 email: AccountsFixtures.primary_address!(invitee)
               })

      assert accepted.accepted_at
    end

    test "a revoked row no longer blocks the address" do
      {org, _owner} = owned_org!()

      invite = invite_for!(org, "re-invite@fluxvale.test")
      revoked = MembershipInvite.revoke!(invite, authorize?: false)
      assert revoked.revoked_at

      assert {:ok, _fresh} =
               create_invite(%{organization_id: org.id, email: "re-invite@fluxvale.test"})
    end
  end

  describe "the state axis" do
    test "an untouched in-window row reads :open" do
      {org, _owner} = owned_org!()
      invite = invite_for!(org, "state-open@fluxvale.test")

      assert reload_with_state!(invite).state == :open
    end

    test "an accepted row reads :accepted — a raced revoke refuses, and a row carrying both stamps still reads accepted" do
      {org, _owner} = owned_org!()
      invitee = AccountsFixtures.user!()
      invite = invite_for!(org, AccountsFixtures.primary_address!(invitee))

      accept!(invite, invitee.id)
      assert reload_with_state!(invite).state == :accepted

      # The revoke action filters accepted rows — a raced revoke
      # refuses instead of stamping the join record (pinned in the
      # accept block below). The calc's precedence still shows for a
      # row that carries both stamps — a state no sanctioned path can
      # produce, so it rides Ash.Seed (the documented exception).
      both =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: "both-stamps@fluxvale.test",
          token_hash: arbitrary_hash(),
          accepted_at: DateTime.add(DateTime.utc_now(), -2, :hour),
          revoked_at: DateTime.add(DateTime.utc_now(), -1, :hour),
          expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
        })

      assert reload_with_state!(both).state == :accepted
    end

    test "a revoked row reads :revoked" do
      {org, _owner} = owned_org!()
      invite = invite_for!(org, "state-revoked@fluxvale.test")

      MembershipInvite.revoke!(invite, authorize?: false)

      assert reload_with_state!(invite).state == :revoked
    end

    test "a past-window row reads :expired — a state no action can produce" do
      {org, _owner} = owned_org!()

      invite =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: "state-expired@fluxvale.test",
          token_hash: arbitrary_hash(),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        })

      assert reload_with_state!(invite).state == :expired
    end
  end

  describe "accept" do
    test "single-fire: the second accept refuses and the stamp never moves" do
      {org, _owner} = owned_org!()
      invitee = AccountsFixtures.user!()
      invite = invite_for!(org, AccountsFixtures.primary_address!(invitee))

      accepted = accept!(invite, invitee.id)

      assert {:error, _stale} = accept(invite, invitee.id)
      assert reload_with_state!(invite).accepted_at == accepted.accepted_at

      # Exactly one membership — the second accept joined nobody.
      assert org_membership_count(org, invitee.id) == 1
    end

    test "a revoked invite cannot accept" do
      {org, _owner} = owned_org!()
      invite = invite_for!(org, "accept-revoked@fluxvale.test")

      MembershipInvite.revoke!(invite, authorize?: false)

      assert {:error, _stale} = accept(invite, AccountsFixtures.user!().id)
      assert reload_with_state!(invite).state == :revoked
    end

    test "revoking an ACCEPTED invite refuses — the join record is never stamped" do
      {org, _owner} = owned_org!()
      invitee = AccountsFixtures.user!()
      invite = invite_for!(org, AccountsFixtures.primary_address!(invitee))

      accepted = accept!(invite, invitee.id)

      assert {:error, _stale} = MembershipInvite.revoke(invite, authorize?: false)

      # The accepted record keeps its stamp; the state stays accepted.
      fresh = reload_with_state!(invite)
      assert fresh.accepted_at == accepted.accepted_at
      assert fresh.revoked_at == nil
      assert fresh.state == :accepted
    end

    test "an expired invite cannot accept" do
      {org, _owner} = owned_org!()

      invite =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: "accept-expired@fluxvale.test",
          token_hash: arbitrary_hash(),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
        })

      assert {:error, _stale} = accept(invite, AccountsFixtures.user!().id)
      assert reload_with_state!(invite).state == :expired
    end

    test "a failed join rolls the whole accept back — no accepted_at without a membership" do
      {org, _owner} = owned_org!()
      invitee = AccountsFixtures.user!()

      # The invitee is ALREADY a member (the system path) — a state the
      # create action cannot produce for orgs; the operation's
      # pre-check normally answers first, so this drives the action's
      # in-transaction join straight into unique_user_per_org.
      Membership.create!(
        %{organization_id: org.id, user_id: invitee.id, role: :member},
        authorize?: false
      )

      invite = invite_for!(org, AccountsFixtures.primary_address!(invitee))

      assert {:error, _duplicate_membership} = accept(invite, invitee.id)

      # The rollback: the row stays open — no accepted_at, no second
      # membership.
      assert reload_with_state!(invite).state == :open
      assert org_membership_count(org, invitee.id) == 1
    end

    test "supersede_expired retires only the stale arm of one (org, email)" do
      {org, _owner} = owned_org!()

      # The stale arms: expired, unstamped rows — a state no action can
      # produce (expiry), so they ride Ash.Seed. Two addresses pin the
      # scoping: only the named (org, email) retires. (A same-address
      # in-window row cannot coexist here — the partial index forbids
      # two stampless rows for one (org, email), expiry included.)
      past = DateTime.add(DateTime.utc_now(), -1, :hour)

      stale =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: "supersede-target@fluxvale.test",
          token_hash: arbitrary_hash(),
          expires_at: past
        })

      other_stale =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: "other-arm@fluxvale.test",
          token_hash: arbitrary_hash(),
          expires_at: past
        })

      assert :ok = MembershipInvite.supersede_expired(org.id, "supersede-target@fluxvale.test")

      assert %{revoked_at: stamped} = Ash.load!(stale, :revoked_at, authorize?: false)
      assert stamped

      # The other address's row stays untouched.
      assert %{revoked_at: nil} = Ash.load!(other_stale, :revoked_at, authorize?: false)

      # An ACCEPTED row (even a long-expired one) is never the stale
      # arm — the accepted_at guard protects the join record.
      invitee2 = AccountsFixtures.user!()

      accepted_stale =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: AccountsFixtures.primary_address!(invitee2),
          token_hash: arbitrary_hash(),
          accepted_at: ~U[2024-06-01 12:00:00Z],
          expires_at: past
        })

      assert :ok =
               MembershipInvite.supersede_expired(
                 org.id,
                 AccountsFixtures.primary_address!(invitee2)
               )

      assert %{revoked_at: nil, accepted_at: kept} =
               Ash.load!(accepted_stale, [:revoked_at, :accepted_at], authorize?: false)

      assert kept
    end

    test "accept and decline get no actor path — the token actions forbid under policies" do
      {org, owner} = owned_org!()
      invite = invite_for!(org, "forbidden-path@fluxvale.test")

      assert {:error, %Ash.Error.Forbidden{}} =
               accept(invite, owner.id, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} = MembershipInvite.decline(invite, actor: owner)
    end
  end

  describe "decline" do
    test "a revoked invite cannot decline — direct action pin" do
      {org, _owner} = owned_org!()
      invite = invite_for!(org, "decline-revoked@fluxvale.test")

      MembershipInvite.revoke!(invite, authorize?: false)

      assert {:error, _stale} = MembershipInvite.decline(invite, authorize?: false)
      assert reload_with_state!(invite).state == :revoked
    end

    test "an expired invite cannot decline — direct action pin" do
      {org, _owner} = owned_org!()

      invite =
        Ash.Seed.seed!(MembershipInvite, %{
          organization_id: org.id,
          email: "decline-expired@fluxvale.test",
          token_hash: arbitrary_hash(),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
        })

      assert {:error, _stale} = MembershipInvite.decline(invite, authorize?: false)
      assert reload_with_state!(invite).state == :expired
    end
  end

  describe "policies" do
    test "members of the org read its invites; an outsider reads nothing of it" do
      {org, owner} = owned_org!()
      member = AccountsFixtures.user!()

      Membership.create!(
        %{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      invite = invite_for!(org, "read-policy@fluxvale.test")

      # The owner (an org member) sees the row.
      assert [%MembershipInvite{id: id}] = invite_query(org, owner)
      assert id == invite.id

      # A plain member sees it too (the pending list's read grant).
      assert [%MembershipInvite{id: ^id}] = invite_query(org, member)

      # An outsider to the org — the relationship filter scopes them to
      # nothing of it.
      assert [] = invite_query(org, AccountsFixtures.user!())
    end

    test "invite and revoke are owner-only" do
      {org, owner} = owned_org!()
      member = AccountsFixtures.user!()

      Membership.create!(
        %{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      assert {:error, %Ash.Error.Forbidden{}} =
               create_invite(
                 %{organization_id: org.id, email: "member-cant-invite@fluxvale.test"},
                 actor: member
               )

      invite = invite_for!(org, "member-cant-revoke@fluxvale.test")

      assert {:error, %Ash.Error.Forbidden{}} = MembershipInvite.revoke(invite, actor: member)

      # The owner path works.
      assert {:ok, _revoked} = MembershipInvite.revoke(invite, actor: owner)
    end

    test "a stranger cannot invite" do
      {org, _owner} = owned_org!()
      stranger = AccountsFixtures.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               create_invite(
                 %{organization_id: org.id, email: "stranger-cant-invite@fluxvale.test"},
                 actor: stranger
               )
    end
  end

  # ---- helpers ---------------------------------------------------------

  # An arbitrary, unique digest for precondition rows — the value's
  # shape is what matters (64-hex), not what it hashes.
  defp arbitrary_hash do
    n = System.unique_integer([:positive])
    seed = Integer.to_string(n)

    :sha256
    |> :crypto.hash(seed)
    |> Base.encode16(case: :lower)
  end

  defp owned_org! do
    owner = AccountsFixtures.user!()
    {AccountsFixtures.owned_org!(owner), owner}
  end

  # The digest rides the action's private argument — the input map
  # cannot carry it, so every create here goes through set_argument
  # (the MintPat shape). Actorless precondition calls run authorize?:
  # false (the bootstrap posture); actor calls run the policies.
  defp create_invite(attrs, opts \\ []) do
    {token_hash, attrs} = Map.pop(attrs, :token_hash, arbitrary_hash())

    opts =
      if Keyword.has_key?(opts, :actor) do
        opts
      else
        Keyword.put(opts, :authorize?, false)
      end

    MembershipInvite
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:token_hash, token_hash)
    |> Ash.Changeset.for_create(:create, attrs, opts)
    |> Ash.create()
  end

  defp create_invite!(attrs) do
    {:ok, invite} = create_invite(attrs)
    invite
  end

  defp invite_for!(org, email) do
    create_invite!(%{organization_id: org.id, email: email})
  end

  defp accept(invite, user_id, opts \\ []) do
    # The digest-shaped argument rides set_argument (private — the code
    # interface's surface cannot carry it, the MintPat shape).
    # Actorless calls run authorize?: false (the token path); an actor
    # call runs the policies (the default-forbid pin).
    opts =
      if Keyword.has_key?(opts, :actor) do
        opts
      else
        Keyword.put(opts, :authorize?, false)
      end

    invite
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:user_id, user_id)
    |> Ash.Changeset.for_update(:accept, %{}, opts)
    |> Ash.update()
  end

  defp accept!(invite, user_id) do
    {:ok, accepted} = accept(invite, user_id)
    accepted
  end

  defp reload_with_state!(invite) do
    MembershipInvite
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(id == ^invite.id)
    |> Ash.Query.load(:state)
    |> Ash.read_one!(authorize?: false)
  end

  defp org_membership_count(org, user_id) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user_id)
    |> Ash.count!(authorize?: false)
  end

  defp invite_query(org, actor) do
    MembershipInvite
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(organization_id == ^org.id)
    |> Ash.read!()
  end
end
