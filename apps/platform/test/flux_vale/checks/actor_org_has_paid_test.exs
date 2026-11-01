defmodule FluxVale.Checks.ActorOrgHasPaidTest do
  @moduledoc false

  # The paid-once gate on private-access enablement: exactly one ledger
  # shape qualifies — a `:purchase` credit of at least $1 (the
  # whole-cents floor). The $3 signup welcome grant and goodwill
  # adjustments deliberately do not count (a bot gets welcome credits,
  # never a card), and a wallet-less org has never paid.

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Checks.ActorOrgHasPaid
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  describe "org_paid?/1" do
    test "a welcome-only org has not paid — the signup grant is not a card" do
      {org, _wallet} = welcome_wallet!()
      refute ActorOrgHasPaid.org_paid?(org.id)
    end

    test "a $1 purchase credit has paid the org" do
      {_org, wallet} = welcome_wallet!()
      {:ok, _entry} = Billing.credit_wallet(wallet, 100)
      assert ActorOrgHasPaid.org_paid?(wallet.organization_id)
    end

    test "a 99¢ purchase does not — the $1 floor has teeth" do
      {_org, wallet} = welcome_wallet!()
      {:ok, _entry} = Billing.credit_wallet(wallet, 99)
      refute ActorOrgHasPaid.org_paid?(wallet.organization_id)
    end

    test "a goodwill adjustment credit does not pay the org" do
      {_org, wallet} = welcome_wallet!()
      {:ok, _entry} = Billing.grant_credits(wallet, 500, reason: :adjustment)
      refute ActorOrgHasPaid.org_paid?(wallet.organization_id)
    end

    test "a refund credit does not pay the org — the reason has teeth too" do
      {_org, wallet} = welcome_wallet!()
      {:ok, _entry} = Billing.credit_wallet(wallet, 500, reason: :refund)
      refute ActorOrgHasPaid.org_paid?(wallet.organization_id)
    end

    test "an org holding welcome AND a $1 purchase has paid — the purchase entry is what counts" do
      # The exists-filter only needs one qualifying row; the welcome
      # balance around it is irrelevant.
      {_org, wallet} = welcome_wallet!()
      {:ok, _entry} = Billing.credit_wallet(wallet, 100)
      assert ActorOrgHasPaid.org_paid?(wallet.organization_id)
    end

    test "a wallet-less org has never paid" do
      {org, _owner} = BillingFixtures.grant_free_org!()
      refute ActorOrgHasPaid.org_paid?(org.id)
    end
  end

  describe "the check itself" do
    test "describe/1 names the gate" do
      assert ActorOrgHasPaid.describe([]) == "the org has paid at least once (a $1+ top-up)"
    end

    test "an actor with no org passes — the create's own org-required validation answers" do
      # Ash.Seed.seed! — the only way to produce an org-less user: the
      # create action's JIT change always provisions one (the documented
      # seed! exception).
      orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})

      create_subject = Ash.Changeset.for_create(AccessGateway, :create, %{}, authorize?: false)

      # create changesets carry no org yet → the actor path → :none → pass
      assert ActorOrgHasPaid.match?(orgless, %{subject: create_subject}, [])
    end

    test "a reload failure fails closed — a struct naming no row never passes" do
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)
      BillingFixtures.mark_paid!(wallet)

      # The in-memory struct CLAIMS the paid org, but its primary key
      # names no row: the fresh DB read fails and the gate answers
      # false instead of trusting the caller.
      phantom = %AccessGateway{id: Ecto.UUID.generate(), organization_id: org.id}
      changeset = Ash.Changeset.for_update(phantom, :resume, %{}, authorize?: false)

      refute ActorOrgHasPaid.match?(nil, %{subject: changeset}, [])
    end

    test "a non-changeset subject fails closed — even for a paid actor" do
      # The old create-stance catch-all routed queries/action-inputs to
      # the actor path: a paid actor answered true on an arbitrary
      # subject. Fail closed.
      paid_actor =
        User.create!("paid-probe-subject-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      BillingFixtures.mark_user_paid!(paid_actor)

      refute ActorOrgHasPaid.match?(paid_actor, %{subject: %AccessGateway{}}, [])
    end

    test "an atomic changeset's placeholder data fails closed without raising" do
      # Ash.reload raises on Ash.Changeset.OriginalDataNotAvailable —
      # the clause before the generic data arm answers :error instead.
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)
      BillingFixtures.mark_paid!(wallet)

      changeset =
        Ash.Changeset.for_update(
          %AccessGateway{id: Ecto.UUID.generate(), organization_id: org.id},
          :resume,
          %{},
          authorize?: false
        )

      atomic = %{changeset | data: %Ash.Changeset.OriginalDataNotAvailable{}}

      refute ActorOrgHasPaid.match?(nil, %{subject: atomic}, [])
    end

    test "a forged nil organization_id on an update answers the ROW's org, never the actor's" do
      # The exploit this closes: route the update by its nil attribute
      # and it takes the create path — the actor's PAID personal org —
      # while the row's own org never paid.
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      row_owner =
        User.create!("paid-probe-row-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      instance =
        Instance.create!(
          %{name: "Row Org", app_version_id: version.id, env_vars: %{}},
          actor: row_owner
        )

      paid_actor =
        User.create!("paid-probe-actor-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      BillingFixtures.mark_user_paid!(paid_actor)

      changeset = Ash.Changeset.for_update(instance, :start, %{}, authorize?: false)
      forged = %{changeset | data: %{instance | organization_id: nil}}

      refute ActorOrgHasPaid.match?(paid_actor, %{subject: forged}, [])
    end
  end

  # The signup shape: welcome grant only — positive balance, never
  # paid. Exactly the org the gate exists to stop.
  defp welcome_wallet! do
    {org, _owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, _welcome} = Billing.grant_credits(wallet, 300)
    {org, wallet}
  end
end
