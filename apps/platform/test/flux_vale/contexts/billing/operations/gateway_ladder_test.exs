defmodule FluxVale.Billing.Operations.GatewayLadderTest do
  @moduledoc false

  # ADR-0039 §5's MUST-FIX (#268): the runway and the zero-balance
  # ladder counted instances only. A gateway debit invisible to burn
  # would let the runway over-estimate; a ladder with no gateway arm
  # would never suspend an unfunded gateway. These pin both halves, and
  # they are the tests that would have failed before the extension.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @month_seconds 2_629_746
  @gateway_cents 200

  setup do
    InstanceFixtures.local_cluster!()

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
    stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
    :ok
  end

  describe "ComputeRunway — the projection half" do
    test "an active gateway's rate is in the burn" do
      {org, _owner, wallet} = wallet!(1_000)
      _gateway = AccessFixtures.gateway!(org, monthly_cents: @gateway_cents)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # Same monthly→hourly floor the instance side uses.
      assert runway.burn_micro_cents_per_hour == hourly(@gateway_cents)
      # And the runway is now finite — the whole point of the fix.
      assert runway.runway_hours != :infinity
    end

    test "a suspended gateway burns nothing — the projection matches the accrual arm" do
      {org, _owner, wallet} = wallet!(1_000)
      _gateway = AccessFixtures.gateway!(org, state: :suspended)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == 0
      assert runway.runway_hours == :infinity
    end

    test "a needs_attention gateway burns nothing" do
      {org, _owner, wallet} = wallet!(1_000)
      _gateway = AccessFixtures.gateway!(org, state: :needs_attention)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == 0
    end

    test "instance and gateway burn add up" do
      {org, user, wallet} = wallet!(1_000)

      version = InstanceFixtures.app_version!()

      instance =
        Instance.create!(
          %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
          actor: user
        )

      reached = InstanceFixtures.walk_to!(instance, :running)
      InstanceFixtures.pin!(reached, namespace: "fluxvale-app-#{instance.id}")

      _gateway = AccessFixtures.gateway!(org, monthly_cents: @gateway_cents)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # fixture size is 100¢/mo → the sum is strictly greater than
      # either half alone, which is what "the gateway is visible" means.
      assert runway.burn_micro_cents_per_hour == hourly(100) + hourly(@gateway_cents)
    end
  end

  describe "SweepZeroBalance — the action half" do
    test "at balance ≤ 0 an active gateway suspends" do
      {org, _owner, wallet} = drained_wallet!()
      gateway = AccessFixtures.gateway!(org, monthly_cents: @gateway_cents)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)

      assert gateway.id in summary.suspended_gateway_ids

      fresh = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert fresh.state == :suspended
      # The anchor is parked: the suspended interval cannot bill on
      # resume.
      assert fresh.metering_since == nil
    end

    test "a suspend failure is logged, not swallowed" do
      {org, _owner, wallet} = drained_wallet!()
      _gateway = AccessFixtures.gateway!(org, monthly_cents: @gateway_cents)

      expect(Tailscale, :scale_gateway, fn _gateway, _replicas -> {:error, :cluster_down} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, summary} = Billing.sweep_zero_balance(wallet)
          # Nothing claims to have been suspended: the id list is what
          # this pass actually changed.
          assert summary.suspended_gateway_ids == []
        end)

      # ...but the operator can see why an unfunded gateway is still up.
      assert log =~ "suspend failed"
    end

    test "a funded wallet leaves the gateway active" do
      {org, _owner, wallet} = wallet!(10_000)
      gateway = AccessFixtures.gateway!(org, monthly_cents: @gateway_cents)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)

      assert summary.suspended_gateway_ids == []
      assert AccessGateway.get_by_id!(gateway.id, authorize?: false).state == :active
    end

    test "a second pass over a suspended gateway is a no-op" do
      {org, _owner, wallet} = drained_wallet!()
      _gateway = AccessFixtures.gateway!(org, monthly_cents: @gateway_cents)

      assert {:ok, _summary} = Billing.sweep_zero_balance(wallet)

      # The suspend arm's own guard: no second K8s call (the sweep
      # re-enters this arm every hour while the balance stays ≤ 0).
      reject(Tailscale, :scale_gateway, 2)

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)
      # Nothing scaled a second time, and the summary says so: the id
      # list is what this pass actually suspended, not what it walked
      # past (an already-parked gateway is not a suspension).
      assert summary.suspended_gateway_ids == []
    end

    test "the destroy arm tears gateways down before their instances" do
      # Funded first: the instance create carries the #124 deploy gate,
      # so the drain has to happen after the workload exists.
      {org, owner, wallet} = wallet!(100)
      _instance = AccessFixtures.private_instance!(org, owner)
      _gateway = AccessFixtures.gateway!(org, monthly_cents: @gateway_cents)
      # Below zero (the destroy ladder's own threshold — the stop arm is
      # ≤ 0, destroy is < 0).
      {:ok, _entry} = Billing.debit_wallet(wallet, 101 * 10_000, reason: :adjustment)

      # Push the destroy clock past its window (the anchor is the
      # ladder's own state, set through its settled action).
      stale = DateTime.add(DateTime.utc_now(), -31, :day)

      wallet
      |> Ash.Changeset.for_update(:set_ladder_state, %{negative_since: stale}, authorize?: false)
      |> Ash.update!()

      assert {:ok, summary} = Billing.sweep_zero_balance(wallet)

      assert summary.destroyed_ids != []
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
end
