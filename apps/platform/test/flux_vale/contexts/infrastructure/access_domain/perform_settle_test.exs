defmodule FluxVale.Infrastructure.AccessDomain.PerformSettleTest do
  @moduledoc false

  # ADR-0040 §11's accrual: custom-domain billing on the gateway settle
  # discipline — advisory wallet lock, prorated micro-cents over the
  # Gregorian month, keyless debit, anchor advance in one transaction.
  # The serving arms (:verified and :needs_attention) are the only
  # accrual arms, and the RATE IS THE CONFIG — the override test is the
  # parameterization deliverable.

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RemoveAccessDomain
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  @month_seconds 2_629_746
  @monthly_cents 200
  @domain_name "apps.customer.com"

  setup do
    # Registration issues the verification Certificate — the cluster
    # call rides the create's transaction (the claim tests' stubs).
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)

    # The suspension funnel's cluster legs (used to stage :suspended
    # rows through the real action, never a raw write).
    Mimic.copy(EdgeRoutes)
    Mimic.copy(RemoveAccessDomain)
    stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, _instance, _domain -> :ok end)
    stub(RemoveAccessDomain, :unclaim_tailnet_state, fn _domain -> :ok end)

    {org, owner, wallet} = wallet!(10_000)

    %{org: org, owner: owner, wallet: wallet}
  end

  describe "settle" do
    test "prorates the configured rate over the open interval", %{owner: owner} do
      domain = verified_domain!(owner)

      # One full Gregorian month of open interval bills exactly the
      # configured monthly rate (the constant settle and the runway
      # share).
      pin_anchor!(domain, ago(@month_seconds))

      assert {:ok, settled} = settle(domain)

      assert domain_ledger_total(settled.organization_id) == -@monthly_cents
      # The anchor advanced to (about) now.
      assert DateTime.diff(DateTime.utc_now(), settled.metering_since, :second) < 5
    end

    test "a sub-cent interval accrues into the wallet carryover, no ledger row", %{owner: owner} do
      domain = verified_domain!(owner)

      # One hour at 200¢/mo ≈ 2_737 µ¢ — a real fraction, well under a
      # cent, so the pool moves and the ledger stays silent.
      pin_anchor!(domain, ago(3600))

      assert {:ok, settled} = settle(domain)

      assert domain_ledger_total(settled.organization_id) == 0
      assert settled_wallet(settled.organization_id).carryover > 0
    end

    test "a tick that prorates to zero posts nothing and still advances", %{owner: owner} do
      domain = verified_domain!(owner)

      pin_anchor!(domain, ago(1))

      assert {:ok, settled} = settle(domain)

      assert domain_ledger_total(settled.organization_id) == 0
      assert DateTime.diff(DateTime.utc_now(), settled.metering_since, :second) < 5
    end

    test "a fresh domain arms the anchor without billing from the epoch", %{owner: owner} do
      # The verified row's anchor is nil until the first settle.
      domain = verified_domain!(owner)
      assert domain.metering_since == nil

      assert {:ok, settled} = settle(domain)

      assert domain_ledger_total(settled.organization_id) == 0
      assert settled.metering_since
    end

    test "a needs_attention domain accrues — both serving arms bill", %{owner: owner} do
      # The stance: needs_attention is the cert's healing state whose
      # issued wildcard is still valid — the routes and the claims
      # stand, so the owner is getting the domain and it bills.
      domain = verified_domain!(owner)
      pin_anchor!(domain, ago(@month_seconds))

      attention =
        domain
        |> Ash.Changeset.for_update(:mark_needs_attention, %{}, authorize?: false)
        |> Ash.update!()

      assert {:ok, settled} = settle(attention)

      assert domain_ledger_total(settled.organization_id) == -@monthly_cents
    end

    test "a suspended domain accrues nothing — the ladder parked its anchor", %{owner: owner} do
      domain = verified_domain!(owner)
      pinned = pin_anchor!(domain, ago(@month_seconds))

      # Through the real funnel (not a forced state write): the
      # suspension takes both tails dark and parks the cursor, which is
      # the invariant the settle's non-serving branch relies on.
      {:ok, suspended} = AccessDomain.mark_suspended(pinned, authorize?: false)
      assert suspended.metering_since == nil

      assert {:ok, settled} = settle(suspended)

      assert domain_ledger_total(settled.organization_id) == 0
    end

    test "leaving the serving arms bills to the transition, then parks (defensive arm)", %{
      owner: owner
    } do
      # Defensive: production reaches this arm only through the race
      # the fresh FOR UPDATE re-read exists for — a row that left the
      # serving arms with its window still open (a demotion predating
      # the anchor-parking discipline). The re-pin stages that open
      # window; its write (`updated_at`) is the transition instant the
      # park arm bills to — never past it, the gateway's
      # never-past-it discipline. Month-ago anchor → transition ≈ a
      # full month, billed exactly.
      domain = verified_domain!(owner)
      {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      pin_anchor!(suspended, ago(@month_seconds))

      assert {:ok, settled} = settle(suspended)

      billed = domain_ledger_total(settled.organization_id)
      assert billed == -@monthly_cents

      # The window is closed: a second tick bills nothing.
      assert settled.metering_since == nil

      assert {:ok, _again} = settle(settled)
      assert domain_ledger_total(settled.organization_id) == billed
    end

    test "a debit failure rolls the settle back — nothing posts, the anchor stands", %{
      owner: owner
    } do
      domain = verified_domain!(owner)
      pinned_at = ago(@month_seconds)
      pin_anchor!(domain, pinned_at)

      stub(Billing, :debit_wallet, fn _wallet, _micros, _opts ->
        {:error, :forced}
      end)

      assert {:error, _reason} = settle(domain)

      # The debit and the anchor share the transaction: nothing
      # posted, the window did not move — the retry re-bills the same
      # interval (the anchor is the retry arbiter).
      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      assert domain_ledger_total(fresh.organization_id) == 0
      assert DateTime.diff(fresh.metering_since, pinned_at, :second) < 5
    end

    test "a mispriced config is a configuration error — money paths fail closed" do
      previous = Application.get_env(:flux_vale, :access_domain_pricing)

      on_exit(fn -> Application.put_env(:flux_vale, :access_domain_pricing, previous) end)

      for bad <- [0, -200, "free"] do
        Application.put_env(:flux_vale, :access_domain_pricing, monthly_cents: bad)

        assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
          AccessDomain.monthly_cents()
        end
      end
    end

    test "pending and failed domains never accrue", %{owner: owner} do
      pending = pending_domain!(owner)

      assert {:ok, settled} = settle(pending)
      assert domain_ledger_total(settled.organization_id) == 0
      assert settled.metering_since == nil

      failed =
        pending
        |> Ash.Changeset.for_update(:mark_failed, %{}, authorize?: false)
        |> Ash.update!()

      assert {:ok, settled_failed} = settle(failed)
      assert domain_ledger_total(settled_failed.organization_id) == 0
      assert settled_failed.metering_since == nil
    end

    test "a platform domain never accrues", %{org: org} do
      # The fluxvale.app hostname is free (§11): platform rows are not
      # on the settle's arms, whatever their state.
      platform_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

      platform =
        AccessDomain.mint_platform!(
          %{domain: platform_domain, organization_id: org.id},
          authorize?: false
        )

      assert {:ok, settled} = settle(platform)

      assert domain_ledger_total(settled.organization_id) == 0
      assert settled.metering_since == nil
    end

    test "the ledger row carries the domain's subject attribution", %{owner: owner} do
      domain = verified_domain!(owner)
      pin_anchor!(domain, ago(@month_seconds))

      assert {:ok, _settled} = settle(domain)

      entry = latest_domain_entry(domain.organization_id)

      assert entry.reason == :usage
      assert entry.type == :debit
      assert entry.subject == "access-domain:#{domain.id}"
    end

    test "the rate follows the config override — the parameterization is the deliverable" do
      previous = Application.get_env(:flux_vale, :access_domain_pricing)

      on_exit(fn -> Application.put_env(:flux_vale, :access_domain_pricing, previous) end)

      Application.put_env(:flux_vale, :access_domain_pricing, monthly_cents: 500)

      {org, owner, _wallet} = wallet!(10_000)
      domain = verified_domain!(owner)
      pin_anchor!(domain, ago(@month_seconds))

      assert {:ok, _settled} = settle(domain)

      # The accrual moved with the config: 500¢/mo, not the compiled 200.
      assert domain_ledger_total(org.id) == -500
      assert AccessDomain.monthly_cents() == 500
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp wallet!(balance_cents) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)

    if balance_cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, balance_cents, reason: :adjustment)
    end

    {org, owner, wallet}
  end

  defp settle(domain) do
    domain
    |> Ash.Changeset.for_update(:perform_settle, %{}, authorize?: false)
    |> Ash.update()
  end

  # Settlement's cursor is not on any accept list (it is the settle's
  # own write); staging it here uses the system action that owns it.
  defp pin_anchor!(domain, at) do
    domain
    |> Ash.Changeset.for_update(:settle_anchors, %{metering_since: at}, authorize?: false)
    |> Ash.update!()
  end

  defp pending_domain!(owner) do
    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: @domain_name}, actor: owner)

    domain
  end

  defp verified_domain!(owner) do
    pending = pending_domain!(owner)

    Ash.update!(pending, %{cert_secret_ref: "cert-secret"},
      action: :mark_verified,
      authorize?: false
    )
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # Only this domain's postings — the wallet's opening grant is not
  # what these tests are about (the gateway settle tests' stance).
  defp domain_ledger_total(organization_id) do
    organization_id
    |> entries()
    |> Enum.filter(&domain_entry?/1)
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end

  defp latest_domain_entry(organization_id) do
    organization_id
    |> entries()
    |> Enum.find(&domain_entry?/1)
  end

  defp entries(organization_id) do
    wallet = settled_wallet(organization_id)

    LedgerEntry
    |> Ash.Query.filter(wallet_id == ^wallet.id)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  # Nil-safe: the opening grant carries no subject (additive column).
  defp domain_entry?(%LedgerEntry{subject: subject}) when is_binary(subject),
    do: String.starts_with?(subject, "access-domain:")

  defp domain_entry?(_entry), do: false

  defp settled_wallet(organization_id) do
    {:ok, wallet} = Billing.ensure_wallet(%FluxVale.Accounts.Organization{id: organization_id})
    Ash.get!(Billing.Wallet, wallet.id, authorize?: false)
  end
end
