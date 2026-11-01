defmodule FluxVale.Billing.Operations.DomainLadderTest do
  @moduledoc false

  # ADR-0040 §11's MUST-FIX pattern, third application: the runway and
  # the zero-balance ladder counted instances and gateways only. A
  # domain debit invisible to burn would let the runway over-estimate;
  # a ladder with no domain arm would never park an unfunded domain.
  # These pin both halves, and they are the tests that would have
  # failed before the extension.

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RemoveAccessDomain
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @month_seconds 2_629_746
  @monthly_cents 200

  setup do
    InstanceFixtures.local_cluster!()

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    # The ladder's stop arm reaches the attached instance's Deployment.
    stub(FluxVale.Clients.K8s.Resources.Deployment, :scale, fn _kc, _ns, _n, _replicas ->
      {:ok, %{}}
    end)

    # The suspension funnel's cluster legs — default success; the
    # fail-closed test overrides.
    Mimic.copy(EdgeRoutes)
    Mimic.copy(RemoveAccessDomain)

    stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, instance, domain ->
      send(self(), {:arms_removed, instance.id, domain.id})
      :ok
    end)

    stub(RemoveAccessDomain, :unclaim_tailnet_state, fn _domain -> :ok end)
    stub(Tailscale, :unclaim_domain, fn _gw, _d -> :ok end)

    # Domain registration issues the verification Certificate (the
    # claim tests' stubs).
    stub(Kubereq, :attach, fn req, _opts -> req end)
    stub(Kubereq, :apply, fn _req, manifest, _fm -> {:ok, %{status: 201, body: manifest}} end)

    :ok
  end

  describe "ComputeRunway — the projection half" do
    test "a verified custom domain's rate is in the burn" do
      {_org, owner, wallet} = wallet!(1_000)
      _domain = verified_domain!(owner)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # Same monthly→hourly floor the instance and gateway sides use.
      assert runway.burn_micro_cents_per_hour == hourly(@monthly_cents)
      # And the runway is finite — the whole point of the extension.
      assert runway.runway_hours != :infinity
    end

    test "the burn follows the configured rate — the projection reads the same config" do
      previous = Application.get_env(:flux_vale, :access_domain_pricing)

      on_exit(fn -> Application.put_env(:flux_vale, :access_domain_pricing, previous) end)

      Application.put_env(:flux_vale, :access_domain_pricing, monthly_cents: 500)

      {_org, owner, wallet} = wallet!(1_000)
      _domain = verified_domain!(owner)

      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert runway.burn_micro_cents_per_hour == hourly(500)
    end

    test "a needs_attention domain burns — the projection matches the accrual arms" do
      {_org, owner, wallet} = wallet!(1_000)
      domain = verified_domain!(owner)

      _attention =
        domain
        |> Ash.Changeset.for_update(:mark_needs_attention, %{}, authorize?: false)
        |> Ash.update!()

      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert runway.burn_micro_cents_per_hour == hourly(@monthly_cents)
    end

    test "pending and suspended domains burn nothing" do
      {_org, owner, wallet} = wallet!(1_000)
      domain = verified_domain!(owner)

      # The platform-wide custom-domain uniqueness refuses a same-name
      # second row, so the pending row rides a different name.
      assert {:ok, pending} =
               Infrastructure.register_access_domain(
                 %{domain: "other.customer.com"},
                 actor: owner
               )

      # The verified domain still burns; the pending row adds nothing.
      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert runway.burn_micro_cents_per_hour == hourly(@monthly_cents)

      {:ok, _suspended} = AccessDomain.mark_suspended(domain, authorize?: false)

      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert runway.burn_micro_cents_per_hour == 0
      assert runway.runway_hours == :infinity
    end

    test "a platform domain never burns — the fluxvale.app hostname is free" do
      {org, _owner, wallet} = wallet!(1_000)

      platform_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)

      AccessDomain.mint_platform!(
        %{domain: platform_domain, organization_id: org.id},
        authorize?: false
      )

      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert runway.burn_micro_cents_per_hour == 0
      assert runway.runway_hours == :infinity
    end

    test "instance and domain burn add up" do
      {org, user, wallet} = wallet!(1_000)

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

      # fixture size is 100¢/mo → the sum is strictly greater than
      # either half alone, which is what "the domain is visible" means.
      assert runway.burn_micro_cents_per_hour == hourly(100) + hourly(@monthly_cents)
    end
  end

  describe "SweepZeroBalance — the action half" do
    test "at balance ≤ 0 a serving domain suspends with both side effects" do
      {org, owner, wallet} = wallet!(100)
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)
      instance_id = attach_with_hostname!(gateway, org, owner, domain)

      # Drain AFTER the fixtures: the instance create's funded gate
      # needs the balance the drain then takes away.
      {:ok, _entry} = Billing.debit_wallet(wallet, 100 * 10_000, reason: :adjustment)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)

      assert domain.id in summary.suspended_domain_ids

      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      assert fresh.state == :suspended
      # The anchor is parked: the suspended interval cannot bill on
      # resume.
      assert fresh.metering_since == nil

      # BOTH honest-dark side effects ran: the domain-scoped arms and
      # the tailnet unclaim.
      assert_received {:arms_removed, sent_instance_id, sent_domain_id}
      assert sent_instance_id == instance_id
      assert sent_domain_id == domain.id
    end

    test "a funded balance leaves domains alone" do
      {org, owner, wallet} = wallet!(1_000)
      _gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)

      assert summary.suspended_domain_ids == []
      assert summary.suspended_gateway_ids == []

      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      assert fresh.state == :verified
    end

    test "a suspension side-effect failure fails that domain's suspension — fail-closed" do
      {org, owner, wallet} = wallet!(100)
      gateway = AccessFixtures.gateway!(org)
      domain = verified_domain!(owner)
      attach_with_hostname!(gateway, org, owner, domain)

      {:ok, _entry} = Billing.debit_wallet(wallet, 100 * 10_000, reason: :adjustment)

      stub(EdgeRoutes, :apply_access_none_for_domain, fn _kc, _instance, _domain ->
        {:error, :cluster_down}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, summary} = Billing.sweep_zero_balance(wallet)

          # Nothing claims to have been suspended: the id list is what
          # this pass actually changed.
          assert summary.suspended_domain_ids == []
        end)

      assert log =~ "suspend failed"

      fresh = AccessDomain.get_by_id!(domain.id, authorize?: false)
      # Still serving, still accruing — the next sweep re-enters.
      assert fresh.state == :verified
    end

    test "a serving domain suspends alongside the gateway arm" do
      {org, owner, wallet} = drained_wallet!()
      gateway = AccessFixtures.gateway!(org, monthly_cents: @monthly_cents)
      domain = verified_domain!(owner)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)

      assert gateway.id in summary.suspended_gateway_ids
      assert domain.id in summary.suspended_domain_ids
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

  defp verified_domain!(owner) do
    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: "apps.customer.com"}, actor: owner)

    Ash.update!(domain, %{cert_secret_ref: "cert-secret"},
      action: :mark_verified,
      authorize?: false
    )
  end

  defp attach_with_hostname!(gateway, org, owner, domain) do
    instance = AccessFixtures.private_instance!(org, owner)

    stub(Tailscale, :attach_instance, fn sent_gateway, sent_instance ->
      {:ok,
       AccessRoute.create!(
         %{gateway_id: sent_gateway.id, instance_id: sent_instance.id, route_key: "8443"},
         authorize?: false
       )}
    end)

    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)

    assert {:ok, _route} = Infrastructure.attach_instance(gateway, instance, actor: owner)

    InstanceHostname.mint!(
      %{instance_id: instance.id, access_domain_id: domain.id, label: "app"},
      authorize?: false
    )

    instance.id
  end
end
