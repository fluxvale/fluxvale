defmodule FluxVale.Accounts.Operations.SetMemberRoleTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Operations.SetMemberRole
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  setup do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)

    {:ok, owner: owner, org: org}
  end

  test "an owner promotes a member to owner through the seam", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    assert {:ok, promoted} = Accounts.set_member_role(owner, membership, :owner)
    assert promoted.role == :owner
  end

  test "demoting the org's only owner classifies the guard refusal", %{owner: owner, org: org} do
    assert {:error, :last_owner} =
             Accounts.set_member_role(owner, row(org, owner), :member)
  end

  test "the guard copy is the plain sentence, no em-dashes, no semicolons" do
    message = SetMemberRole.guard_message()

    assert message =~ "must keep at least one owner"
    refute message =~ "—"
    refute message =~ ";"
  end

  test "a member calling the seam bubbles the policy refusal", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    seed_member!(org, member)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.set_member_role(member, row(org, owner), :member)
  end

  test "a role outside the enum is refused — the single enum axis (no finer roles)", %{
    owner: owner,
    org: org
  } do
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    # The Stripe-model constraint: owner and member are the only values;
    # anything else is a cast error, never a new class of grant.
    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.set_member_role(owner, membership, :admin)

    assert row(org, member).role == :member
  end

  test "a stale struct naming a vanished row fails closed — Forbidden, not :last_owner", %{
    owner: owner,
    org: org
  } do
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    # The row moves (teardown here) between the caller's load and the
    # seam call: the ownership check re-reads the row and fails closed
    # (the ActorOwnsMembershipOrg stance) — no write, no mislabel.
    Ash.destroy!(membership, authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.set_member_role(owner, membership, :owner)
  end

  # Nothing outside the invite accept flow creates :member rows —
  # preconditions ride the create action with authorize?: false (the
  # bootstrap posture, mirroring seeds).
  defp seed_member!(org, user) do
    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )
  end

  defp row(org, user) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read_one!(authorize?: false)
  end
end
