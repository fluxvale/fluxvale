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
  alias FluxVale.TestSupport.BillingFixtures

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

    test "a non-changeset subject routes to the actor path — the create stance" do
      orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})

      assert ActorOrgHasPaid.match?(orgless, %{subject: %AccessGateway{}}, [])
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
