defmodule FluxVale.Billing.Operations.ComputeRunwayTest do
  @moduledoc false

  # #124's runway arithmetic: balance ÷ burn, where burn is the org's
  # live rates — running at monthly, stopped at storage-only, nothing
  # else. Amounts come from the fixture size (100¢/mo, 10¢ stopped).

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  describe "call/1" do
    setup do
      InstanceFixtures.local_cluster!()
      version = InstanceFixtures.app_version!()
      {:ok, version: version}
    end

    test "a running instance burns its monthly rate across a 30-day month", %{version: version} do
      {user, wallet} = wallet!(100)
      instance!(user, :running, version)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # 100¢/mo → 100 * 10_000 µ¢ / 720h, floored per instance
      assert runway.burn_micro_cents_per_hour == 1388
      assert runway.balance_cents == 100
      assert_in_delta runway.runway_hours, 1_000_000 / 1388, 0.01
    end

    test "a stopped instance burns the storage-only rate", %{version: version} do
      {user, wallet} = wallet!(10)
      instance!(user, :stopped, version)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == div(10 * 10_000, 720)
    end

    test "rates sum across instances; other statuses burn nothing", %{version: version} do
      {user, wallet} = wallet!(500)
      instance!(user, :running, version)
      instance!(user, :stopped, version)

      # a :pending row carries no rate (never anchored)
      Instance.create!(
        %{name: "Pending #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # per-instance flooring, summed: 1388 (running) + 138 (stopped)
      assert runway.burn_micro_cents_per_hour == 1526
    end

    test "no instances → no burn, infinite runway" do
      {_user, wallet} = wallet!(5)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == 0
      assert runway.runway_hours == :infinity
    end

    test "a bare wallet (no entries) reads zero balance and infinite runway" do
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.balance_cents == 0
      assert runway.runway_hours == :infinity
    end
  end

  # Exact funding on a grant-free org (the billing fixture's shape): no
  # welcome grant in the arithmetic — the wallet lands at precisely
  # balance_cents.
  defp wallet!(balance_cents) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)

    if balance_cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, balance_cents, reason: :adjustment)
    end

    {owner, wallet}
  end

  defp instance!(user, status, version) do
    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    chain = %{
      running: [:deploying, :starting, :running],
      stopped: [:deploying, :starting, :running, :stopped]
    }

    path = Map.fetch!(chain, status)

    reached =
      Enum.reduce(path, instance, fn status, acc ->
        {:ok, updated} = InstanceK8s.update_status(acc, status, nil)
        updated
      end)

    InstanceFixtures.pin!(reached, namespace: "fluxvale-app-#{instance.id}")
  end
end
