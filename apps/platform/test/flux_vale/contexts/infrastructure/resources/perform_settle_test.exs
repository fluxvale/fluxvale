defmodule FluxVale.Infrastructure.Instance.PerformSettleTest do
  @moduledoc """
  #121's settlement: flat-rate accrual over elapsed time — running time
  inside the tick at `monthly_cents`, the rest at `stopped_monthly_cents`,
  exact across stop/start transitions inside a tick (the unbilled carry
  folds each closed interval at the stop, so churn drops nothing); the
  creation-time snapshot prices the grace, the live size row (or, for a
  custom allocation, the live anchor formula from the instance's own
  allocation — #186) after; the advanced anchors are the retry arbiter
  (a committed settle can never re-bill its interval).

  Anchors and carries are backdated through `pin!` — past timestamps are
  states the actions can't produce (the documented seed/force exception).
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  # The average Gregorian month (PerformSettle's proration base) and the
  # seeded "small" prices at B′ (#206) — assertions compute from the
  # spec formula.
  @month_seconds 2_629_746
  @monthly_cents 335
  @stopped_cents 40

  setup do
    # Grant-free org — the welcome grant rides JIT provisioning (#122),
    # and the settle arithmetic owns the wallet's whole balance.
    {org, user} = BillingFixtures.grant_free_org!()

    version =
      InstanceFixtures.app_version!(
        monthly_cents: @monthly_cents,
        stopped_monthly_cents: @stopped_cents
      )

    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "Billable", app_version_id: version.id, env_vars: %{}},
        actor: user,
        # authorize?: false — the wallet is grant-free by design below,
        # and #124's deploy gate would forbid a member create at 0;
        # settle arithmetic is gate-orthogonal (system-op posture).
        authorize?: false
      )

    {:ok, wallet} = Billing.ensure_wallet(org)

    %{org: org, user: user, wallet: wallet, instance: instance, version: version}
  end

  describe "flat-rate accrual" do
    test "a month running debits the full monthly rate", %{wallet: wallet, instance: instance} do
      instance = running!(instance)
      month_ago = ago(@month_seconds)
      backdate!(instance, storage_metering_since: month_ago, running_since: month_ago)

      assert {:ok, _settled} = settle!(instance)

      assert usage_entries(wallet) == [%{amount: -@monthly_cents}]
      assert {:ok, -@monthly_cents} = Billing.balance(wallet, authorize?: false)
      # The month lands on the exact cent; the floor eats the sub-µ¢
      # settle latency, and the bound tolerates slow-run drift.
      assert reload_wallet!(wallet).carryover in 0..2
    end

    test "a month stopped debits the storage-only rate", %{
      wallet: wallet,
      instance: instance
    } do
      stopped = stopped!(instance)
      month_ago = ago(@month_seconds)

      # The long-stopped shape: no open interval, no pending carry —
      # storage metering spans the whole tick.
      backdate!(stopped,
        storage_metering_since: month_ago,
        running_since: nil,
        unbilled_running_usec: 0
      )

      assert {:ok, _settled} = settle!(stopped)

      assert usage_entries(wallet) == [%{amount: -@stopped_cents}]
      assert {:ok, -@stopped_cents} = Billing.balance(wallet, authorize?: false)
    end

    test "a stop inside the tick prorates both streams (the carry folds the interval)", %{
      wallet: wallet,
      instance: instance
    } do
      stopped = stopped!(instance)

      # What the stop transition would have folded: 30m of running time
      # since the cursor; the rest of the hour bills stopped.
      backdate!(stopped,
        storage_metering_since: ago(3_600),
        running_since: nil,
        unbilled_running_usec: 1_800_000_000
      )

      assert {:ok, _settled} = settle!(stopped)

      # 30m at the full rate + 30m at the stopped rate — sub-cent, so it
      # all pools (no ledger row) and the carry zeroes with the cursor.
      # The drift bound absorbs the stopped-rate tail between backdate
      # and settle (sub-cent per ~23s).
      assert usage_entries(wallet) == []

      expected_dec = prorated(1_800, 1_800)
      expected = Decimal.to_integer(expected_dec)
      assert reload_wallet!(wallet).carryover in expected..(expected + 3)

      fresh = reload_instance!(stopped)
      assert fresh.running_since == nil
      assert fresh.unbilled_running_usec == 0
      assert DateTime.compare(fresh.storage_metering_since, ago(5)) == :gt
    end

    test "a start inside the tick prorates both streams", %{
      wallet: wallet,
      instance: instance
    } do
      instance = running!(instance)
      started = ago(1_800)

      backdate!(instance,
        storage_metering_since: ago(3_600),
        running_since: started,
        unbilled_running_usec: 0
      )

      assert {:ok, _settled} = settle!(instance)

      assert usage_entries(wallet) == []

      expected_dec = prorated(1_800, 1_800)
      expected = Decimal.to_integer(expected_dec)
      assert reload_wallet!(wallet).carryover in expected..(expected + 3)

      # Still running: the interval anchor survives for the next tick;
      # the carry is what settles.
      fresh = reload_instance!(instance)
      assert fresh.running_since == started
      assert fresh.unbilled_running_usec == 0
    end

    test "stop/start churn inside one tick never drops the interval (the abuse shape)", %{
      wallet: wallet,
      instance: instance
    } do
      # Three days running, stopped and restarted within the same tick:
      # the carry holds all three days at the full rate — the days can
      # not be repriced as storage-only by churn (the folded carry is
      # 33.0¢ at B′: -33 posts, the fraction pools).
      running = running!(instance)
      three_days = 3 * 86_400

      backdated =
        backdate!(running,
          storage_metering_since: ago(three_days),
          running_since: ago(three_days)
        )

      {:ok, stopped} = InstanceK8s.update_status(backdated, :stopped, nil)
      {:ok, restarting} = InstanceK8s.update_status(stopped, :starting, nil)
      {:ok, restarted} = InstanceK8s.update_status(restarting, :running, nil)

      assert stopped.running_since == nil
      assert stopped.unbilled_running_usec > three_days * 1_000_000 - 1_000_000_000

      assert {:ok, _settled} = settle!(restarted)

      # 33.0¢ of full rate: -33 posts, the fraction pools.
      assert usage_entries(wallet) == [%{amount: -33}]

      expected_dec = prorated(three_days, 0)
      expected_micros = Decimal.to_integer(expected_dec)

      pooled = expected_micros - div(expected_micros, 10_000) * 10_000
      assert reload_wallet!(wallet).carryover in pooled..(pooled + 100)
    end

    test "fractions pool per wallet across instances", %{
      user: user,
      wallet: wallet,
      instance: first
    } do
      first = running!(first)

      created =
        Instance.create!(
          %{name: "Also Billable", app_version_id: first.app_version_id, env_vars: %{}},
          actor: user,
          # Same gate-orthogonal posture as the setup create.
          authorize?: false
        )

      second = running!(created)

      anchor = ago(3_600)

      backdate!(first, storage_metering_since: anchor, running_since: anchor)

      backdate!(second,
        storage_metering_since: anchor,
        running_since: anchor,
        unbilled_running_usec: 0
      )

      assert {:ok, _settled} = settle!(first)
      assert {:ok, _settled} = settle!(second)

      # Same org, same full-rate hour each: the pool doubles — #120's
      # no-per-instance-dust rule under #121's per-instance settles.
      assert usage_entries(wallet) == []

      per_instance_dec = prorated(3_600, 0)
      per_instance = Decimal.to_integer(per_instance_dec)

      expected_pool = per_instance * 2

      assert reload_wallet!(wallet).carryover in expected_pool..(expected_pool + 4)
    end
  end

  describe "retry and edge semantics" do
    test "a committed settle is its own replay guard — the second run bills nothing", %{
      wallet: wallet,
      instance: instance
    } do
      instance = running!(instance)
      month_ago = ago(@month_seconds)
      backdate!(instance, storage_metering_since: month_ago, running_since: month_ago)

      assert {:ok, _settled} = settle!(instance)
      assert {:ok, _settled} = settle!(reload_instance!(instance))

      assert usage_entries(wallet) == [%{amount: -@monthly_cents}]
      assert {:ok, -@monthly_cents} = Billing.balance(wallet, authorize?: false)
      assert reload_wallet!(wallet).carryover in 0..2
    end

    test "a never-ran instance settles to a no-op (the storage cursor stays unset)", %{
      wallet: wallet,
      instance: instance
    } do
      assert {:ok, _settled} = settle!(instance)

      assert usage_entries(wallet) == []
      assert {:ok, 0} = Billing.balance(wallet, authorize?: false)

      fresh = reload_instance!(instance)
      assert fresh.storage_metering_since == nil
      assert fresh.unbilled_running_usec == 0
    end

    test "an unpriced instance (pre-#121 drift) accrues nothing and keeps its anchors", %{
      wallet: wallet,
      instance: instance
    } do
      instance = running!(instance)
      month_ago = ago(@month_seconds)

      backdate!(instance,
        storage_metering_since: month_ago,
        running_since: month_ago,
        size_id: nil,
        grandfathered_until: nil,
        grandfathered_monthly_cents: nil,
        grandfathered_stopped_monthly_cents: nil
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _settled} = settle!(instance)
        end)

      assert log =~ "skipped settlement"

      assert usage_entries(wallet) == []
      assert {:ok, 0} = Billing.balance(wallet, authorize?: false)

      # Anchors deliberately stay: the forgiven gap stays visible.
      fresh = reload_instance!(instance)
      assert fresh.storage_metering_since == month_ago
    end
  end

  describe "pricing" do
    test "the creation-time snapshot holds until grandfathered_until lapses", %{
      wallet: wallet,
      instance: instance
    } do
      instance = running!(instance)
      size = Ash.get!(Size, instance.size_id, authorize?: false)
      Size.update!(size, %{monthly_cents: 999}, authorize?: false)

      backdate!(instance,
        storage_metering_since: ago(@month_seconds),
        running_since: ago(@month_seconds),
        grandfathered_until: DateTime.add(DateTime.utc_now(), 1, :day)
      )

      assert {:ok, _settled} = settle!(instance)

      assert usage_entries(wallet) == [%{amount: -@monthly_cents}]
    end

    test "after the lapse the live size row prices the tick", %{
      wallet: wallet,
      instance: instance
    } do
      instance = running!(instance)
      size = Ash.get!(Size, instance.size_id, authorize?: false)
      Size.update!(size, %{monthly_cents: 999}, authorize?: false)

      backdate!(instance,
        storage_metering_since: ago(@month_seconds),
        running_since: ago(@month_seconds),
        grandfathered_until: ago(1)
      )

      assert {:ok, _settled} = settle!(instance)

      assert usage_entries(wallet) == [%{amount: -999}]
    end

    test "a custom allocation settles at its formula snapshot inside the grace (#186)", %{
      wallet: wallet,
      user: user,
      version: version
    } do
      custom =
        Instance.create!(
          %{
            name: "Custom",
            app_version_id: version.id,
            env_vars: %{},
            cpu_cores: Decimal.new("1"),
            memory_mb: 512,
            storage_gb: 10
          },
          actor: user,
          authorize?: false
        )

      assert custom.size_id == nil
      assert custom.grandfathered_monthly_cents == 391

      running = running!(custom)

      backdate!(running,
        storage_metering_since: ago(@month_seconds),
        running_since: ago(@month_seconds)
      )

      assert {:ok, _settled} = settle!(running)

      # A month running at 1 CPU / 512 MB / 10 GB: the v5 formula's
      # 391¢ (the wizard shows the same figure).
      assert usage_entries(wallet) == [%{amount: -391}]
    end

    test "a custom allocation past its grace settles at the live formula from its own allocation (#186)",
         %{wallet: wallet, user: user, version: version} do
      custom_lapsed =
        Instance.create!(
          %{
            name: "Custom lapsed",
            app_version_id: version.id,
            env_vars: %{},
            cpu_cores: Decimal.new("1"),
            memory_mb: 512,
            storage_gb: 10
          },
          actor: user,
          authorize?: false
        )

      running_lapsed = running!(custom_lapsed)

      backdate!(running_lapsed,
        storage_metering_since: ago(@month_seconds),
        running_since: ago(@month_seconds),
        grandfathered_until: ago(1)
      )

      # No size row to fall back to (size_id nil — the size lookup path
      # would error); the live curve prices the tick from the
      # instance's own allocation.
      assert {:ok, _settled} = settle!(running_lapsed)

      assert usage_entries(wallet) == [%{amount: -391}]
    end
  end

  describe "policy" do
    test "settle_anchors is system-only — members cannot rewrite the cursor", %{
      user: user,
      instance: instance
    } do
      changeset =
        Ash.Changeset.for_update(instance, :settle_anchors, %{
          storage_metering_since: DateTime.utc_now()
        })

      assert {:error, %Ash.Error.Forbidden{}} = Ash.update(changeset, actor: user)
    end
  end

  defp settle!(instance) do
    instance
    |> Ash.Changeset.for_update(:perform_settle, %{}, authorize?: false)
    |> Ash.update()
  end

  defp running!(instance), do: InstanceFixtures.walk_to!(instance, :running)

  defp stopped!(instance), do: InstanceFixtures.walk_to!(instance, :stopped)

  # Backdates anchors/carries (and drift-shape fields) via the forced
  # status funnel — past timestamps are states the actions can't produce.
  defp backdate!(instance, attrs) do
    InstanceFixtures.pin!(instance, attrs)
  end

  defp ago(seconds) do
    DateTime.add(DateTime.utc_now(), -seconds, :second)
  end

  # The spec formula, independently stated: running_secs at the monthly
  # rate + stopped_secs at the stopped rate, integer micro-cents floored.
  defp prorated(running_secs, stopped_secs) do
    monthly = Decimal.new(@monthly_cents)

    running =
      monthly
      |> Decimal.mult(Decimal.new(10_000))
      |> Decimal.mult(Decimal.new(running_secs))
      |> Decimal.div(Decimal.new(@month_seconds))

    stopped_rate = Decimal.new(@stopped_cents)

    stopped =
      stopped_rate
      |> Decimal.mult(Decimal.new(10_000))
      |> Decimal.mult(Decimal.new(stopped_secs))
      |> Decimal.div(Decimal.new(@month_seconds))

    running
    |> Decimal.add(stopped)
    |> Decimal.round(0, :floor)
  end

  defp usage_entries(wallet) do
    entries =
      LedgerEntry
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :usage)
      |> Ash.read!(authorize?: false)

    Enum.map(entries, &%{amount: &1.amount})
  end

  defp reload_wallet!(wallet) do
    Ash.get!(Billing.Wallet, wallet.id, authorize?: false)
  end

  defp reload_instance!(instance) do
    Ash.get!(Instance, instance.id, authorize?: false)
  end
end
