defmodule FluxVale.Billing.Operations.ComputeRunwayTest do
  @moduledoc false

  # #124's runway arithmetic: balance ÷ burn, where burn is the org's
  # live rates through the one settlement resolver (#153) — running at
  # the resolved running rate, stopped at the storage-only rate,
  # nothing else, priced over the same Gregorian month settle prorates
  # by. Amounts come from the fixture size (100¢/mo, 10¢ stopped).

  use FluxVale.DataCase, async: true

  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  # The average Gregorian month (#121's constant — settle's proration
  # base) and the fixture size's default prices.
  @month_seconds 2_629_746
  @monthly_cents 100
  @stopped_cents 10

  setup do
    InstanceFixtures.local_cluster!()
    version = InstanceFixtures.app_version!()
    {:ok, version: version}
  end

  describe "call/1" do
    test "a running instance burns its monthly rate across the Gregorian month", %{
      version: version
    } do
      {user, wallet} = wallet!(100)
      instance!(user, :running, version)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # 100¢/mo → div(100 * 10_000 µ¢ * 3600, 2_629_746s), floored per
      # instance — the Gregorian-month constant settle bills by (#121)
      assert runway.burn_micro_cents_per_hour == hourly(@monthly_cents)
      assert runway.balance_cents == 100
      assert_in_delta runway.runway_hours, 1_000_000 / hourly(@monthly_cents), 0.01
    end

    test "a stopped instance burns the storage-only rate", %{version: version} do
      {user, wallet} = wallet!(10)
      instance!(user, :stopped, version)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == hourly(@stopped_cents)
    end

    # #203: a sleeping instance burns the storage-only rate — the
    # runway projection and settlement agree on the asleep stream.
    test "a sleeping instance burns the storage-only rate", %{version: version} do
      {user, wallet} = wallet!(10)
      instance!(user, :sleeping, version)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == hourly(@stopped_cents)
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

      # per-instance flooring, summed: 1368 (running) + 136 (stopped)
      assert runway.burn_micro_cents_per_hour ==
               hourly(@monthly_cents) + hourly(@stopped_cents)
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

  # The #153 disagreement cases: settle prices by the snapshotted
  # size_id + grandfathered_* snapshot, so runway must too — never by
  # the version's live recommended_size or the Size row's current price
  # while the grace stands.
  describe "rate resolution (#153)" do
    test "mid-grace, a live price hike does not move the burn", %{version: version} do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      # Grace stands (created_at + 1y); the live row hikes to 999¢.
      size = Ash.get!(Size, instance.size_id, authorize?: false)
      Size.update!(size, %{monthly_cents: 999}, authorize?: false)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # The creation-time snapshot (100¢) prices the projection.
      assert runway.burn_micro_cents_per_hour == hourly(@monthly_cents)
    end

    test "after the lapse, the live size row prices the burn", %{version: version} do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      size = Ash.get!(Size, instance.size_id, authorize?: false)
      Size.update!(size, %{monthly_cents: 999}, authorize?: false)

      InstanceFixtures.pin!(instance, grandfathered_until: ago(1))

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == hourly(999)
    end

    # The resolver's safe default for rows the backfill missed: no
    # grace clock, no snapshot trust — the live row prices.
    test "a nil grandfathered_until prices live", %{version: version} do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      size = Ash.get!(Size, instance.size_id, authorize?: false)
      Size.update!(size, %{monthly_cents: 999}, authorize?: false)

      InstanceFixtures.pin!(instance, grandfathered_until: nil)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == hourly(999)
    end

    test "a version re-point to a pricier size does not reprice the instance", %{
      version: version
    } do
      {user, wallet} = wallet!(100)
      # The instance's snapshot lands at create; only its existence
      # matters below, not the binding.
      instance!(user, :running, version)

      # Same allocation (ValidateSizeMatchesAllocation), double price —
      # the old runway followed the version's recommended_size and
      # would burn the new rate; the snapshot keeps the old one.
      pricier =
        Size.create!(
          %{
            slug: "repriced-#{System.unique_integer()}",
            cpu_cores: Decimal.new("0.5"),
            memory_mb: 256,
            storage_gb: 0,
            monthly_cents: 200,
            stopped_monthly_cents: 20
          },
          authorize?: false
        )

      AppVersion.update!(version, %{recommended_size_id: pricier.id}, authorize?: false)

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == hourly(@monthly_cents)
    end

    test "a custom allocation burns at the formula rate (#186)", %{version: version} do
      {user, wallet} = wallet!(100)

      custom =
        Instance.create!(
          %{
            name: "Custom #{System.unique_integer()}",
            app_version_id: version.id,
            env_vars: %{},
            cpu_cores: Decimal.new("1"),
            memory_mb: 512,
            storage_gb: 10
          },
          actor: user
        )

      reached = InstanceFixtures.walk_to!(custom, :running)
      InstanceFixtures.pin!(reached, namespace: "fluxvale-app-#{custom.id}")

      assert {:ok, runway} = Billing.compute_runway(wallet)

      # 1 CPU / 512 MB / 10 GB on the v5 curve (#206): 391¢/mo — the
      # same figure the wizard shows and settle bills.
      assert runway.burn_micro_cents_per_hour == hourly(391)
    end

    test "a hand-built half-snapshot (sizeless, clock set, cents nil) burns nothing", %{
      version: version
    } do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      # The formula snapshot is the cents + clock PAIR — a sizeless row
      # missing either half is unpriced, never a crash in the projection.
      InstanceFixtures.pin!(instance,
        size_id: nil,
        grandfathered_monthly_cents: nil,
        grandfathered_stopped_monthly_cents: nil
      )

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == 0
    end

    test "an unpriced instance (pre-#121 drift) burns nothing", %{version: version} do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      # Unpriced = no size AND no formula snapshot (#186 tightened the
      # marker; a nil size alone now means a formula-priced custom).
      InstanceFixtures.pin!(instance,
        size_id: nil,
        grandfathered_until: nil,
        grandfathered_monthly_cents: nil,
        grandfathered_stopped_monthly_cents: nil
      )

      assert {:ok, runway} = Billing.compute_runway(wallet)

      assert runway.burn_micro_cents_per_hour == 0
      assert runway.runway_hours == :infinity
    end
  end

  # #153's exit criterion: agreement by construction — for the same
  # instance (grandfathered, lapsed, unpriced shapes), the warning's
  # burn rate equals what settle bills over the same hour. Settle's µ¢
  # are sub-cent here, so they pool in the wallet carryover; the bound
  # absorbs the sub-µ¢ of settle latency between the backdate and the
  # tick (the settle tests' drift discipline).
  describe "agreement with settle (#153)" do
    test "grandfathered: an hour of running bills at the burn rate", %{version: version} do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      # The live row hikes mid-grace: both paths must price the
      # snapshot anyway — this is the disagreement shape.
      size = Ash.get!(Size, instance.size_id, authorize?: false)
      Size.update!(size, %{monthly_cents: 999}, authorize?: false)

      hour_ago = ago(3_600)

      InstanceFixtures.pin!(instance,
        storage_metering_since: hour_ago,
        running_since: hour_ago
      )

      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert {:ok, _settled} = settle!(instance)

      burn = hourly(@monthly_cents)
      assert runway.burn_micro_cents_per_hour == burn
      assert billed_micro(wallet) in burn..(burn + 5)
    end

    test "lapsed: an hour of running bills at the live burn rate", %{version: version} do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      size = Ash.get!(Size, instance.size_id, authorize?: false)
      Size.update!(size, %{monthly_cents: 999}, authorize?: false)

      hour_ago = ago(3_600)

      InstanceFixtures.pin!(instance,
        storage_metering_since: hour_ago,
        running_since: hour_ago,
        grandfathered_until: ago(1)
      )

      assert {:ok, runway} = Billing.compute_runway(wallet)
      assert {:ok, _settled} = settle!(instance)

      burn = hourly(999)
      assert runway.burn_micro_cents_per_hour == burn
      assert billed_micro(wallet) in burn..(burn + 20)
    end

    test "unpriced: settle forgives and the projection burns nothing", %{version: version} do
      {user, wallet} = wallet!(100)
      instance = instance!(user, :running, version)

      hour_ago = ago(3_600)

      InstanceFixtures.pin!(instance,
        storage_metering_since: hour_ago,
        running_since: hour_ago,
        size_id: nil,
        grandfathered_until: nil,
        grandfathered_monthly_cents: nil,
        grandfathered_stopped_monthly_cents: nil
      )

      assert {:ok, runway} = Billing.compute_runway(wallet)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _settled} = settle!(instance)
        end)

      assert log =~ "skipped settlement"

      assert runway.burn_micro_cents_per_hour == 0
      assert billed_micro(wallet) == 0
    end
  end

  # The spec formula: monthly cents → integer µ¢/h over the average
  # Gregorian month, floored per instance.
  defp hourly(monthly_cents) do
    div(monthly_cents * 10_000 * 3600, @month_seconds)
  end

  # What settle actually billed for the hour: the posted usage cents
  # plus the sub-cent fraction pooled in the carryover (#120's
  # no-dust rule — a whole cent posts, the residue pools).
  defp billed_micro(%Wallet{} = wallet) do
    fresh = Ash.get!(Wallet, wallet.id, authorize?: false)

    entries =
      LedgerEntry
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :usage)
      |> Ash.read!(authorize?: false)

    amounts = Enum.map(entries, & &1.amount)
    posted = -Enum.sum(amounts)

    posted * 10_000 + fresh.carryover
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

    reached = InstanceFixtures.walk_to!(instance, status)
    InstanceFixtures.pin!(reached, namespace: "fluxvale-app-#{instance.id}")
  end

  defp settle!(instance) do
    instance
    |> Ash.Changeset.for_update(:perform_settle, %{}, authorize?: false)
    |> Ash.update()
  end

  defp ago(seconds) do
    DateTime.add(DateTime.utc_now(), -seconds, :second)
  end
end
