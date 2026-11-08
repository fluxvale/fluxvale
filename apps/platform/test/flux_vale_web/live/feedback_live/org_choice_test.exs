defmodule FluxValeWeb.FeedbackLive.OrgChoiceTest do
  @moduledoc """
  The feedback islands' org-picker state (#412 T5): the pure arms of
  `choices`, `default`, and `topup_path` — including the shapes the
  session path cannot produce (an org-less signed-in actor fails the
  auth chain, a personal org without its marker is the #408 legacy row),
  which is exactly why this module is tested directly.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxValeWeb.FeedbackLive.OrgChoice

  describe "choices/1" do
    test "the actor's owned orgs, oldest (personal) first" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)
      team = AccountsFixtures.owned_org!(user)

      assert [%{id: first}, %{id: second}] = OrgChoice.choices(user)
      assert first == personal.id
      assert second == team.id
    end
  end

  describe "default/2" do
    test "the personal org when owned" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)
      team = AccountsFixtures.owned_org!(user)

      assert %{id: picked} = OrgChoice.default(user, [personal, team])
      assert picked == personal.id
    end

    test "the first owned org when the personal org carries no marker (the #408 legacy row)" do
      # A forced attribute change: no writer nulls the marker through
      # actions (provisioning stamps it once) — the unmarked personal
      # org is the pre-backfill data state #408 healed in bulk.
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)
      team = AccountsFixtures.owned_org!(user)

      personal
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:personal_owner_id, nil)
      |> Ash.update!(authorize?: false)

      assert %{id: picked} = OrgChoice.default(user, [team, personal])
      assert picked == team.id
    end

    test "nil for an org-less actor (the seeded straggler shape)" do
      # Ash.Seed.seed! — the only org-less shape (the create action's
      # JIT change always provisions one; the documented exception).
      orgless = Ash.Seed.seed!(User, %{username: "orgless-choice-#{System.unique_integer()}"})

      assert OrgChoice.default(orgless, []) == nil
    end
  end

  describe "topup_path/1" do
    test "the account wizard for nil (the org-less shape)" do
      assert OrgChoice.topup_path(nil) == "/billing/topup"
    end

    test "the account wizard for the personal org (its slug-keyed URL would redirect)" do
      user = AccountsFixtures.user!()
      personal = AccountsFixtures.personal_org!(user)

      assert OrgChoice.topup_path(personal) == "/billing/topup"
    end

    test "the org's own wizard for a team org" do
      user = AccountsFixtures.user!()
      team = AccountsFixtures.owned_org!(user)

      assert OrgChoice.topup_path(team) == "/organizations/#{team.slug}/billing/topup"
    end
  end
end
