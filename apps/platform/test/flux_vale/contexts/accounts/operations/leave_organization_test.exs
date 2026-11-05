defmodule FluxVale.Accounts.Operations.LeaveOrganizationTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Operations.LeaveOrganization
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  setup do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)

    {:ok, owner: owner, org: org}
  end

  test "a member leaves their org through the seam — the row is gone", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    assert :ok = Accounts.leave_organization(member, membership)
    refute row?(org, member)

    # The org and its owner are untouched — leaving is not teardown.
    assert row?(org, owner)
  end

  test "leaving as the org's only owner classifies the guard refusal", %{owner: owner, org: org} do
    assert {:error, :last_owner} = Accounts.leave_organization(owner, row(org, owner))
  end

  test "the guard copy is the plain sentence, no em-dashes, no semicolons" do
    message = LeaveOrganization.guard_message()

    assert message =~ "must keep at least one owner"
    refute message =~ "—"
    refute message =~ ";"
  end

  test "leaving is self-only — another user's row bubbles the policy refusal", %{
    owner: owner,
    org: org
  } do
    member = AccountsFixtures.user!()
    seed_member!(org, member)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.leave_organization(member, row(org, owner))
  end

  test "an owner leaving with a second owner present succeeds", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    seed_owner!(org, member)

    assert :ok = Accounts.leave_organization(owner, row(org, owner))
    assert row?(org, member)
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

    assert {:error, %Ash.Error.Forbidden{}} = Accounts.leave_organization(owner, membership)
  end

  # Nothing outside the invite accept flow creates :member rows, and
  # extra owners have no action at all — preconditions ride the create
  # action with authorize?: false (the bootstrap posture, mirroring
  # seeds).
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

  defp row?(org, user) do
    Membership
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.exists?(authorize?: false)
  end
end
