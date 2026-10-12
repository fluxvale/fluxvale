defmodule FluxVale.Accounts.MembershipTest do
  @moduledoc """
  Membership resource contract (#119): the join is the access model —
  system-only writes, member-scoped reads, one membership per org+user.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts.Membership
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  setup do
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)

    {:ok, user: user, org: org}
  end

  test "role defaults to :owner and the row links user + org", %{user: user, org: org} do
    membership = owner_membership(user, org)

    assert membership.role == :owner
    assert membership.organization_id == org.id
    assert membership.user_id == user.id
  end

  test "a user appears at most once per organization", %{user: user, org: org} do
    assert {:error, %Ash.Error.Invalid{}} =
             Membership.create(%{organization_id: org.id, user_id: user.id, role: :member},
               authorize?: false
             )
  end

  test "actor-driven creation is forbidden (no self-grant)", %{user: user, org: org} do
    stranger = AccountsFixtures.user!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Membership.create(%{organization_id: org.id, user_id: stranger.id, role: :owner},
               actor: user
             )
  end

  test "actor-driven destruction is forbidden", %{user: user, org: org} do
    membership = owner_membership(user, org)

    assert {:error, %Ash.Error.Forbidden{}} =
             Membership.destroy(membership, actor: user)
  end

  test "members read their org's memberships; strangers see only their own", %{
    user: user,
    org: org
  } do
    assert {:ok, mine} = Membership.read(actor: user)
    assert Enum.any?(mine, &(&1.organization_id == org.id and &1.user_id == user.id))

    stranger = AccountsFixtures.user!()

    assert {:ok, theirs} = Membership.read(actor: stranger)
    refute Enum.any?(theirs, &(&1.organization_id == org.id))
  end

  defp owner_membership(user, org) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read_one!(authorize?: false)
  end
end
