defmodule FluxVale.Accounts.Operations.RemoveMemberTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Operations.RemoveMember
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  setup do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.owned_org!(owner)

    {:ok, owner: owner, org: org}
  end

  test "an owner removes a member through the seam — the row is gone", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    membership = seed_member!(org, member)

    assert :ok = Accounts.remove_member(owner, membership)

    refute row?(org, member)
  end

  test "removing the org's only owner (the caller themselves) classifies the guard refusal", %{
    owner: owner,
    org: org
  } do
    assert {:error, :last_owner} = Accounts.remove_member(owner, row(org, owner))
  end

  test "the guard copy is the plain sentence, no em-dashes, no semicolons" do
    message = RemoveMember.guard_message()

    assert message =~ "must keep at least one owner"
    refute message =~ "—"
    refute message =~ ";"
  end

  test "a member calling the seam bubbles the policy refusal", %{owner: owner, org: org} do
    member = AccountsFixtures.user!()
    seed_member!(org, member)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.remove_member(member, row(org, owner))
  end

  test "removing yourself rides :leave, not this seam — refused even with a second owner", %{
    owner: owner,
    org: org
  } do
    second = AccountsFixtures.user!()
    seed_owner!(org, second)

    # The actions stay distinct: self-removal is refused outright (the
    # actor filter), whatever the owner count says.
    assert {:error, %Ash.Error.Invalid{}} = Accounts.remove_member(owner, row(org, owner))
    assert row?(org, owner)
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
