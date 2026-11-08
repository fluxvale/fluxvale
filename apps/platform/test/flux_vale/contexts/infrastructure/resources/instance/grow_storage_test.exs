defmodule FluxVale.Infrastructure.Instance.GrowStorageTest do
  @moduledoc """
  The `:grow_storage` action (#250): online and storage-only — no
  stopped-first fence (running/stopped/sleeping all legal; deleting/lost
  refuse), up-only with both figures named, capability-gated with distinct
  copy for a real no vs a failed probe, settled at the OLD rate before the
  flip, re-priced through the create-equivalent snapshot, and appended to
  the allocation-era trail. System-only: no member policy arm.

  Rows here carry no namespace (pinned nowhere) — the cluster apply is
  attribute-only for them, so the suite needs no K8s stubs beyond the
  capability probe; the apply itself is pinned in
  operations/grow_storage_volume_test.exs.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceAllocationSnapshot
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Pricing
  alias FluxVale.Pricing.Size
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @month_seconds 2_629_746

  setup do
    # The capability probe resolves the cluster's kubeconfig (the
    # stop/start tests' stub shape).
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    :ok
  end

  describe "online statuses" do
    test "a running instance grows — no stopped-first refusal" do
      instance = running!()
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      assert {:ok, grown} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert grown.storage_gb == 10
    end

    test "a stopped instance grows" do
      instance = stopped!()
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      assert {:ok, grown} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert grown.storage_gb == 10
    end

    test "a sleeping instance grows" do
      instance = sleeping!()
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      assert {:ok, grown} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert grown.storage_gb == 10
    end

    test "a deleting instance is refused" do
      instance = InstanceFixtures.pin!(stopped!(), status: :deleting)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message == "cannot grow storage for an instance in deleting state")
             )
    end

    test "a lost instance is refused" do
      instance = InstanceFixtures.pin!(running!(), status: :lost)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message == "cannot grow storage for an instance in lost state")
             )
    end

    # The check-then-act race: a delete bumps no `version`, so the
    # optimistic lock can't fence it. A delete committing between the
    # caller's read and the growth's transaction is caught by the settle's
    # FOR UPDATE re-read inside the transaction.
    test "a delete committing after the read is refused at write time" do
      instance = stopped!()
      stale = Ash.get!(Instance, instance.id, authorize?: false)

      # The race: the row advances to :deleting with no version bump.
      assert {:ok, _deleting} = InstanceK8s.update_status(stale, :deleting, nil)

      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(stale, %{storage_gb: 10}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message == "cannot grow storage for an instance in deleting state")
             )

      # Halt-on-invalid: no era appended, era 1 still open.
      rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
      assert length(rows) == 1
      assert hd(rows).superseded_at == nil
    end
  end

  describe "up-only" do
    test "a shrink is refused, naming both figures — no settle, no era append" do
      {org, owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      created =
        Instance.create!(
          %{name: "Shrink", app_version_id: version.id, env_vars: %{}, storage_gb: 10},
          actor: owner,
          authorize?: false
        )

      # A backdated cursor makes the wallet assertion bite: a wrongly-run
      # settle would post a whole cent over 15 days.
      walked = InstanceFixtures.walk_to!(created, :stopped)

      stopped =
        InstanceFixtures.pin!(walked,
          storage_metering_since: ago(15 * 86_400),
          running_since: nil,
          unbilled_running_usec: 0
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(stopped, %{storage_gb: 5}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message == "storage can never shrink (from 10 GB to 5 GB)")
             )

      assert usage_entries(wallet) == []

      rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
      assert length(rows) == 1
      assert hd(rows).superseded_at == nil
    end

    test "a no-op is refused, naming both figures" do
      instance = stopped!(storage_gb: 10)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message == "storage is unchanged (from 10 GB to 10 GB)")
             )

      rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
      assert length(rows) == 1
    end

    test "a crafted nil reads as absent — the row's storage is the effective target" do
      instance = stopped!(storage_gb: 10)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(instance, %{storage_gb: nil}, authorize?: false)

      assert Enum.any?(
               errors,
               &(&1.message == "storage is unchanged (from 10 GB to 10 GB)")
             )
    end
  end

  describe "capability gate" do
    test "a grow with capability false is refused with the product boundary" do
      instance = stopped!()
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert Enum.any?(errors, &(&1.message == "storage can't be expanded on this cluster yet"))
    end

    test "a probe error refuses with its own copy — not the capability no" do
      instance = stopped!()

      expect(StorageClass, :default_allows_expansion?, fn _kc ->
        {:error, K8s.Error.connection_error("api server on fire")}
      end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert Enum.any?(errors, &(&1.message == "storage expansion check failed — try again"))
      refute Enum.any?(errors, &(&1.message == "storage can't be expanded on this cluster yet"))
    end
  end

  describe "settle-before-flip and re-pricing" do
    setup do
      # Grant-free org — the welcome grant rides JIT provisioning (#122),
      # and the settle arithmetic owns the wallet's whole balance.
      {org, user} = BillingFixtures.grant_free_org!()

      version =
        InstanceFixtures.app_version!(
          monthly_cents: 295,
          default_storage_gb: 10
        )

      InstanceFixtures.local_cluster!()

      created =
        Instance.create!(
          %{name: "Grow billable", app_version_id: version.id, env_vars: %{}},
          actor: user,
          authorize?: false
        )

      {:ok, wallet} = Billing.ensure_wallet(org)
      stopped = InstanceFixtures.walk_to!(created, :stopped)

      %{wallet: wallet, instance: stopped, version: version}
    end

    test "the open interval settles at the OLD stopped rate; the era re-prices through the snapshot",
         %{wallet: wallet, instance: instance, version: version} do
      fifteen_days = 15 * 86_400

      instance =
        InstanceFixtures.pin!(instance,
          storage_metering_since: ago(fifteen_days),
          running_since: nil,
          unbilled_running_usec: 0
        )

      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      before = DateTime.utc_now()
      assert {:ok, grown} = Instance.grow_storage(instance, %{storage_gb: 20}, authorize?: false)
      after_grow = DateTime.utc_now()

      # 15 days at the OLD snapshot's stopped rate (the 10 GB axis, 40¢).
      old_dec = prorated_stopped(40, fifteen_days)

      old_posted =
        old_dec
        |> Decimal.round(0, :floor)
        |> Decimal.to_integer()
        |> div(10_000)

      assert usage_entries(wallet) == [%{amount: -old_posted}]

      assert grown.storage_gb == 20

      # Storage never kicks an instance off its compute class (#558): the
      # row keeps its size, and the storage axis re-prices.
      size = Ash.get!(Size, version.recommended_size_id, authorize?: false)
      storage = Pricing.storage_monthly_cents(grown.storage_gb)

      assert grown.size_id == size.id
      assert grown.grandfathered_monthly_cents == size.monthly_cents + storage
      assert grown.grandfathered_stopped_monthly_cents == storage

      # FRESH clock: a year from THIS growth, not the original create.
      assert DateTime.compare(grown.grandfathered_until, DateTime.shift(before, year: 1)) == :gt

      assert DateTime.compare(grown.grandfathered_until, DateTime.shift(after_grow, year: 1)) ==
               :lt

      # The audit trail: era 1 closed, era 2 open at the new allocation.
      rows =
        InstanceAllocationSnapshot
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.sort(created_at: :asc)
        |> Ash.read!(authorize?: false)

      assert [era1, era2] = rows
      assert era1.superseded_at
      assert era1.storage_gb == 10
      assert era2.storage_gb == 20
      assert era2.monthly_cents == grown.grandfathered_monthly_cents
      assert era2.superseded_at == nil

      assert {:ok, [open]} =
               InstanceAllocationSnapshot.in_force(instance.id, authorize?: false)

      assert open.id == era2.id
    end
  end

  describe "policy" do
    test "a member call is Forbidden — the action is system-only" do
      instance = stopped!()

      # The guard's changes run while the changeset builds; the probe must
      # answer before policy can deny.
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.grow_storage(instance, %{storage_gb: 10}, actor: owner_of(instance))
    end
  end

  describe "broadcast (#250)" do
    test "a growth publishes the updated record on instances:<id>" do
      instance = running!()
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      Phoenix.PubSub.subscribe(FluxVale.PubSub, "instances:#{instance.id}")

      assert {:ok, grown} =
               Instance.grow_storage(instance, %{storage_gb: 10}, authorize?: false)

      assert_received %Ash.Notifier.Notification{
        data: notified,
        action: %{name: :grow_storage}
      }

      assert notified.id == grown.id
      assert notified.storage_gb == 10
    end
  end

  # --- helpers --------------------------------------------------------

  # The wallet's usage ledger rows — the settle-happened detector.
  defp usage_entries(wallet) do
    entries =
      LedgerEntry
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :usage)
      |> Ash.read!(authorize?: false)

    Enum.map(entries, &%{amount: &1.amount})
  end

  # Stopped-stream proration at an arbitrary monthly rate.
  defp prorated_stopped(monthly_cents, secs) do
    monthly_cents
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(10_000))
    |> Decimal.mult(Decimal.new(secs))
    |> Decimal.div(Decimal.new(@month_seconds))
  end

  defp ago(seconds) do
    DateTime.add(DateTime.utc_now(), -seconds, :second)
  end

  defp user do
    User.create!("growth-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # The actor for follow-up lifecycle calls, re-derived from the record
  # the way the data model defines ownership: instance → organization →
  # member (the resize suite's stance).
  defp owner_of(instance) do
    org =
      instance
      |> Ash.load!(:organization, authorize?: false)
      |> Map.get(:organization)

    org
    |> Ash.load!(:members, authorize?: false)
    |> Map.get(:members)
    |> List.first()
  end

  # A fresh instance at the version defaults, walked to the target, with
  # no namespace pinned — the cluster apply is attribute-only.
  defp stopped!(attrs \\ []) when is_list(attrs) do
    created = created!(attrs)
    InstanceFixtures.walk_to!(created, :stopped)
  end

  defp running!(attrs \\ []) when is_list(attrs) do
    created = created!(attrs)
    InstanceFixtures.walk_to!(created, :running)
  end

  defp sleeping!(attrs \\ []) when is_list(attrs) do
    created = created!(attrs)
    InstanceFixtures.walk_to!(created, :sleeping)
  end

  defp created!(attrs) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    base = %{name: "Grow me", app_version_id: version.id, env_vars: %{}}
    params = Map.merge(base, Map.new(attrs))
    Instance.create!(params, actor: user())
  end
end
