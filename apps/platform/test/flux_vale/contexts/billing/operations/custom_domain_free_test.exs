defmodule FluxVale.Billing.Operations.CustomDomainFreeTest do
  @moduledoc false

  # ADR-0040 Amendment 2: custom domains are free. The domain accrual,
  # its settle worker and its runway arm are gone, and the zero-balance
  # ladder no longer suspends a serving domain. These are the assertions
  # that would have failed before the removal.

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @month_seconds 2_629_746

  setup do
    InstanceFixtures.local_cluster!()

    # Domain registration issues the verification Certificate (the
    # claim tests' stubs).
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)

    :ok
  end

  describe "ComputeRunway" do
    test "a verified custom domain adds no burn" do
      {_org, owner, wallet} = wallet!(1_000)
      _domain = verified_domain!(owner)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == 0
      assert runway.runway_hours == :infinity
    end

    test "a needs_attention domain adds no burn either" do
      {_org, owner, wallet} = wallet!(1_000)
      domain = verified_domain!(owner)

      domain
      |> Ash.Changeset.for_update(:mark_needs_attention, %{}, authorize?: false)
      |> Ash.update!()

      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert runway.burn_micro_cents_per_hour == 0
    end

    test "an instance's burn is unchanged by a verified domain" do
      {_org, user, wallet} = wallet!(1_000)

      version = InstanceFixtures.app_version!()

      instance =
        Instance.create!(
          %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
          actor: user
        )

      reached = InstanceFixtures.walk_to!(instance, :running)
      InstanceFixtures.pin!(reached, namespace: "fluxvale-app-#{instance.id}")

      _domain = verified_domain!(user)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # The fixture size is 100¢/mo. The domain contributes exactly
      # zero, so the burn is the instance's hourly rate alone.
      assert runway.burn_micro_cents_per_hour == hourly(100)
    end
  end

  describe "SweepZeroBalance" do
    test "a zero balance leaves a serving domain serving" do
      {_org, owner, wallet} = drained_wallet!()
      domain = verified_domain!(owner)

      assert {:ok, _summary} = Billing.sweep_zero_balance(wallet)

      fresh = Ash.get!(AccessDomain, domain.id, authorize?: false)
      assert fresh.state == :verified
    end
  end

  # --- Helpers ------------------------------------------------------------------

  defp wallet!(balance_cents) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)

    if balance_cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, balance_cents, reason: :adjustment)
    end

    {org, owner, wallet}
  end

  # A wallet at exactly 0 — funded then fully spent, so the ladder's
  # ≤ 0 arm fires without a negative clock.
  defp drained_wallet! do
    {org, owner, wallet} = wallet!(100)
    {:ok, _entry} = Billing.debit_wallet(wallet, 100 * 10_000, reason: :adjustment)

    {org, owner, wallet}
  end

  defp hourly(monthly_cents) do
    div(monthly_cents * 10_000 * 3600, @month_seconds)
  end

  # The register policy requires a paid-once, funded account
  # (ADR-0040 Amendment 2). mark_user_paid! posts the $1 purchase the
  # gate reads and leaves the balance positive.
  defp verified_domain!(owner) do
    BillingFixtures.mark_user_paid!(owner)

    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: "apps.customer.com"}, actor: owner)

    Ash.update!(domain, %{cert_secret_ref: "cert-secret"},
      action: :mark_verified,
      authorize?: false
    )
  end
end
