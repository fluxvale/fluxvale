defmodule FluxVale.Accounts.MembershipLifecycleTest do
  @moduledoc """
  The member lifecycle contract (slice 5 of #408): owners set roles and
  remove members, a membership's own user leaves, and the last-owner
  guard keeps every organization at one owner or more. The guard is the
  COUNT, not the identity — every refusal arm has a second-owner
  sibling that succeeds.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Membership.LastOwnerGuard
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  setup do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)

    {:ok, owner: owner, org: org}
  end

  # ---- policies ---------------------------------------------------------

  test "a member cannot set_role — the owner policy refuses", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    seed_member!(org, member)
    owner_row = row(org, owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             Membership.set_role(owner_row, %{role: :member}, actor: member)
  end

  test "a member cannot remove_member — the owner policy refuses", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    seed_member!(org, member)

    owner_row = row(org, owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             Membership.remove_member(owner_row, actor: member)
  end

  test "leave is self-only — another user's row is Forbidden", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    seed_member!(org, member)

    owner_row = row(org, owner)

    assert {:error, %Ash.Error.Forbidden{}} = Membership.leave(owner_row, actor: member)
  end

  test "an owner can set both directions: promote, then demote", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    # Promote: the member row joins the owner set.
    assert {:ok, promoted} = Membership.set_role(membership, %{role: :owner}, actor: owner)
    assert promoted.role == :owner
    assert owner?(org, member)

    # Demote (the actor is the second owner present — the guard is satisfied).
    assert {:ok, demoted} = Membership.set_role(promoted, %{role: :member}, actor: owner)
    assert demoted.role == :member
    refute owner?(org, member)
  end

  # The self-removal pin (slice 5): removing YOURSELF is the :leave
  # path, so :remove_member refuses it outright — the actor filter
  # rides the DELETE's WHERE and the zero-row write answers the
  # Invalid refusal. A second owner present isolates the filter from
  # the last-owner guard.
  test "an owner removing themselves rides :leave semantics — :remove_member refuses", %{
    owner: owner,
    org: org
  } do
    second = AccountsFixtures.user!()
    seed_owner!(org, second)

    owner_row = row(org, owner)

    assert {:error, %Ash.Error.Invalid{}} = Membership.remove_member(owner_row, actor: owner)

    # The refusal refused nothing: both owner rows stand.
    assert owner?(org, owner)
    assert owner?(org, second)
  end

  # ---- the last-owner guard ---------------------------------------------

  test "demoting the org's only owner is refused — field-scoped, plain", %{
    owner: owner,
    org: org
  } do
    sole_owner = row(org, owner)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Membership.set_role(sole_owner, %{role: :member}, actor: owner)

    assert [%{field: :role, message: message}] = errors
    assert message == Membership.LastOwnerGuard.refusal_message()
    assert owner?(org, owner)
  end

  test "removing the org's only owner is refused — same count, same shape", %{
    owner: owner,
    org: org
  } do
    # The sole owner removing their own row: the guard (before_action)
    # answers before the self-removal filter does.
    sole_owner = row(org, owner)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Membership.remove_member(sole_owner, actor: owner)

    assert [%{field: :role, message: message}] = errors
    assert message == LastOwnerGuard.refusal_message()
    assert owner?(org, owner)
  end

  test "leaving as the last owner is refused", %{owner: owner, org: org} do
    sole_owner = row(org, owner)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Membership.leave(sole_owner, actor: owner)

    assert [%{field: :role, message: message}] = errors
    assert message == LastOwnerGuard.refusal_message()
    assert owner?(org, owner)
  end

  # The guard is the count, not the identity: with a second owner
  # present the same writes go through.
  test "a second owner present lets demote, remove, and leave through", %{
    owner: owner,
    org: org
  } do
    second = AccountsFixtures.user!()
    seed_owner!(org, second)
    third = AccountsFixtures.user!()
    seed_owner!(org, third)
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    third_row = row(org, third)

    # Demote the other owner (the actor is the second owner present).
    assert {:ok, _demoted} = Membership.set_role(third_row, %{role: :member}, actor: owner)
    refute owner?(org, third)

    # Remove a plain member.
    assert :ok = Membership.remove_member(membership, actor: owner)
    refute member?(org, member)

    # Leave with an owner still standing.
    owner_row = row(org, owner)
    assert :ok = Membership.leave(owner_row, actor: owner)
    refute member?(org, owner)
    assert owner?(org, second)
  end

  # ---- ownership transfer composes from the primitives ------------------

  test "transfer: promote the successor, demote the old owner — one owner before, two mid-flow, one after",
       %{
         owner: owner,
         org: org
       } do
    successor = AccountsFixtures.user!()
    membership = seed_member!(org, successor)

    assert owner_count(org) == 1

    assert {:ok, _promoted} = Accounts.set_member_role(owner, membership, :owner)
    assert owner_count(org) == 2

    old_owner_row = row(org, owner)
    assert {:ok, _demoted} = Accounts.set_member_role(successor, old_owner_row, :member)
    assert owner_count(org) == 1
    assert owner?(org, successor)
    refute owner?(org, owner)
  end

  # ---- the default destroy stays system-only ----------------------------

  test "the default :destroy stays system-only — even the row's own user", %{
    owner: owner,
    org: org
  } do
    member = AccountsFixtures.user!()
    seed_member!(org, member)

    # The lifecycle writes ride the NAMED actions; the plain destroy is
    # teardown and stays actor-forbidden.
    owner_row = row(org, owner)
    member_row = row(org, member)

    assert {:error, %Ash.Error.Forbidden{}} = Membership.destroy(owner_row, actor: owner)
    assert {:error, %Ash.Error.Forbidden{}} = Membership.destroy(member_row, actor: member)
  end

  # ---- preconditions ----------------------------------------------------

  # Nothing outside the invite accept flow creates :member rows, and
  # extra owners have no action at all — preconditions ride the create
  # action with authorize?: false (the bootstrap posture, mirroring
  # seeds; the gate under test is the lifecycle policy, not the create).
  defp seed_member!(org, user) do
    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )
  end

  defp seed_owner!(org, user) do
    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :owner},
      authorize?: false
    )
  end

  defp row(org, user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read_one!(authorize?: false)
  end

  defp member?(org, user) do
    Membership
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.exists?(authorize?: false)
  end

  defp owner?(org, user) do
    Membership
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id and role == :owner)
    |> Ash.exists?(authorize?: false)
  end

  defp owner_count(org) do
    Membership
    |> Ash.Query.filter(organization_id == ^org.id and role == :owner)
    |> Ash.count!(authorize?: false)
  end
end
