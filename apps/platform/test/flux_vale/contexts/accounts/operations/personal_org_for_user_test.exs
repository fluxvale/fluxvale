defmodule FluxVale.Accounts.Operations.PersonalOrgForUserTest do
  @moduledoc """
  The canonical personal-org read (#408): the org whose
  `personal_owner_id` names the user — the explicit marker, not any
  ownership derivation. `:none` when no marked org exists.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Accounts
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures

  describe "call/2" do
    test "returns the org provisioning marked — the marker names the user" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, personal} = Accounts.personal_org_for_user(user.id, authorize?: false)
      assert personal.id == org.id
      assert personal.personal_owner_id == user.id
    end

    test "a later-created owned org never becomes the personal org" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)
      _team = AccountsFixtures.owned_org!(user)

      assert {:ok, ^personal} = Accounts.personal_org_for_user(user.id, authorize?: false)
    end

    test "an owned but unmarked org is not the personal org (the derivation is gone)" do
      # Ash.Seed.seed! — the sanctioned escape: the create action
      # JIT-provisions a marked org, and this shape needs an org-less
      # user owning an unmarked org — exactly what the marker semantics
      # must NOT resolve as personal (the old derivation would have).
      user = Ash.Seed.seed!(User, %{email: "unmarked-owner@fluxvale.test"})
      _owned = AccountsFixtures.owned_org!(user)

      assert :none = Accounts.personal_org_for_user(user.id, authorize?: false)
    end

    test "a user with no org at all reads :none" do
      # Ash.Seed.seed! — the create action provisions (see above).
      orgless = Ash.Seed.seed!(User, %{email: "orgless@fluxvale.test"})

      assert :none = Accounts.personal_org_for_user(orgless.id, authorize?: false)
    end

    test "the actor-authorized path answers the same (the actor propagates)" do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)

      assert {:ok, personal} = Accounts.personal_org_for_user(user.id, actor: user)
      assert personal.id == org.id
    end
  end
end
