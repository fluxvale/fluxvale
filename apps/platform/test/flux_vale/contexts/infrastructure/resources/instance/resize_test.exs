defmodule FluxVale.Infrastructure.Instance.ResizeTest do
  @moduledoc """
  The `:resize` action (#493): stopped-first, CPU/RAM both ways,
  storage up-only behind the live capability probe, priced through the
  one snapshot choice (create-equivalent cents + fresh 1-year clock),
  member+funded policies, and the append-only audit trail closing the
  old era and opening the new one.

  Rows here carry no namespace (pinned nowhere) — the cluster re-apply
  is attribute-only for them, so the suite needs no cluster stubs; the
  apply itself is pinned in operations/resize_instance_test.exs.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
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

  setup do
    # The capability probe resolves the cluster's kubeconfig (the
    # stop/start tests' stub shape).
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    :ok
  end

  describe "stopped-only" do
    test "a running instance is refused" do
      instance = running!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(instance, %{memory_mb: 512}, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot resize instance in running"))
    end

    test "a pending instance is refused" do
      instance = created!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(instance, %{memory_mb: 512}, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot resize instance in pending"))
    end

    test "a sleeping instance is refused" do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      created =
        Instance.create!(%{name: "Sleeper", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      instance = InstanceFixtures.walk_to!(created, :sleeping)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(instance, %{memory_mb: 512}, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message =~ "cannot resize instance in sleeping"))
    end

    # The check-then-act race (Finding B): start bumps no `version`, so
    # the optimistic lock can't fence it. A start committing between the
    # caller's read and the resize's transaction is caught by the
    # settle's FOR UPDATE re-read inside the transaction.
    test "a start committing after the read is refused at write time" do
      instance = stopped!()
      owner = owner_of(instance)

      # The stale struct — fetched before the row moved underneath it.
      stale = Ash.get!(Instance, instance.id, authorize?: false)

      # The race: the row advances to :starting with no version bump.
      assert {:ok, _starting} = InstanceK8s.update_status(stale, :starting, nil)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(stale, %{memory_mb: 1024}, actor: owner)

      assert Enum.any?(
               errors,
               &(&1.message =~ "cannot resize instance in starting state (must be stopped)")
             )

      # Halt-on-invalid: no era appended, era 1 still open.
      rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
      assert length(rows) == 1
      assert hd(rows).superseded_at == nil
    end
  end

  describe "CPU/RAM both directions" do
    test "cpu up and cpu down both land" do
      instance = stopped!()

      assert {:ok, up} =
               Instance.resize(instance, %{cpu_cores: Decimal.new("2")},
                 actor: owner_of(instance)
               )

      assert Decimal.eq?(up.cpu_cores, Decimal.new("2"))
      assert up.memory_mb == 256

      assert {:ok, down} =
               Instance.resize(up, %{cpu_cores: Decimal.new("0.25")}, actor: owner_of(up))

      assert Decimal.eq?(down.cpu_cores, Decimal.new("0.25"))
    end

    test "memory up and memory down both land" do
      instance = stopped!()

      assert {:ok, up} = Instance.resize(instance, %{memory_mb: 1024}, actor: owner_of(instance))
      assert up.memory_mb == 1024
      assert Decimal.eq?(up.cpu_cores, Decimal.new("0.5"))

      assert {:ok, down} = Instance.resize(up, %{memory_mb: 128}, actor: owner_of(up))
      assert down.memory_mb == 128
    end
  end

  describe "no-op and partial resizes" do
    test "an all-dims no-op is refused (audit noise)" do
      instance = stopped!()

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(instance, %{}, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message == "allocation is unchanged"))
    end

    test "a partial resize holds the unspecified dims" do
      instance = stopped!()

      assert {:ok, resized} =
               Instance.resize(instance, %{memory_mb: 1024}, actor: owner_of(instance))

      assert resized.memory_mb == 1024
      assert Decimal.eq?(resized.cpu_cores, instance.cpu_cores)
      assert resized.storage_gb == instance.storage_gb
    end

    test "a crafted nil dim reads as absent — the row keeps its value, priced accordingly" do
      instance = stopped!()

      assert {:ok, resized} =
               Instance.resize(
                 instance,
                 %{cpu_cores: nil, memory_mb: 1024},
                 actor: owner_of(instance)
               )

      # The guard normalized the nil to absent: cpu keeps the row's
      # value, memory flipped — never a nil write.
      assert Decimal.eq?(resized.cpu_cores, instance.cpu_cores)
      assert resized.memory_mb == 1024
      assert resized.storage_gb == instance.storage_gb

      # Priced at the effective allocation (memory off the default →
      # the formula, no size).
      rates =
        Pricing.price_allocation(%{
          cpu_cores: instance.cpu_cores,
          memory_mb: 1024,
          storage_gb: instance.storage_gb
        })

      assert resized.grandfathered_monthly_cents == rates.monthly_cents
      assert resized.size_id == nil
    end
  end

  describe "floors and maxima" do
    test "zero cpu / zero memory are refused" do
      instance = stopped!()

      assert {:error, %Ash.Error.Invalid{errors: cpu_errors}} =
               Instance.resize(instance, %{cpu_cores: Decimal.new("0")},
                 actor: owner_of(instance)
               )

      assert Enum.any?(cpu_errors, &(&1.field == :cpu_cores))

      assert {:error, %Ash.Error.Invalid{errors: mem_errors}} =
               Instance.resize(instance, %{memory_mb: 0}, actor: owner_of(instance))

      assert Enum.any?(mem_errors, &(&1.field == :memory_mb))
    end

    test "storage past the ceiling is refused" do
      instance = stopped!()

      assert {:error, %Ash.Error.Invalid{errors: storage_errors}} =
               Instance.resize(instance, %{storage_gb: 10_241}, actor: owner_of(instance))

      assert Enum.any?(storage_errors, &(&1.field == :storage_gb))
    end
  end

  describe "storage up-only" do
    test "a shrink is refused, naming both figures" do
      # The funded-org path (the grant-free fixture + its wallet), like
      # the settle-facing suites — so the wallet/trail assertions below
      # are possible.
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
      stopped = InstanceFixtures.walk_to!(created, :stopped)

      InstanceFixtures.pin!(stopped,
        storage_metering_since: DateTime.add(DateTime.utc_now(), -15 * 86_400),
        running_since: nil,
        unbilled_running_usec: 0
      )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(stopped, %{storage_gb: 5}, actor: owner)

      assert Enum.any?(
               errors,
               &(&1.message == "storage can never shrink (from 10 GB to 5 GB)")
             )

      # Pins Ash's halt-on-invalid-changeset: no settle, no era append, on
      # refusal.
      assert usage_entries(wallet) == []

      rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
      assert length(rows) == 1

      era1 = hd(rows)
      assert era1.instance_id == stopped.id
      assert era1.storage_gb == 10
      assert era1.superseded_at == nil
    end

    test "a grow with capability false is refused" do
      instance = stopped!()
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, false} end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(instance, %{storage_gb: 10}, actor: owner_of(instance))

      assert Enum.any?(errors, &(&1.message == "storage can't be expanded on this cluster yet"))
    end

    test "a probe error refuses the resize with its own copy — not the capability no" do
      instance = stopped!()

      expect(StorageClass, :default_allows_expansion?, fn _kc ->
        {:error, K8s.Error.connection_error("api server on fire")}
      end)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Instance.resize(instance, %{storage_gb: 10}, actor: owner_of(instance))

      # Distinct from the capability-false copy: a failed probe is a
      # "try again", not a product boundary.
      assert Enum.any?(errors, &(&1.message == "storage expansion check failed — try again"))
      refute Enum.any?(errors, &(&1.message == "storage can't be expanded on this cluster yet"))
    end

    test "a grow with capability true lands" do
      instance = stopped!()
      expect(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      assert {:ok, resized} =
               Instance.resize(instance, %{storage_gb: 10}, actor: owner_of(instance))

      assert resized.storage_gb == 10
    end

    test "a CPU/RAM-only resize never probes the cluster" do
      instance = stopped!()
      reject(StorageClass, :default_allows_expansion?, 1)

      assert {:ok, resized} =
               Instance.resize(instance, %{memory_mb: 1024}, actor: owner_of(instance))

      assert resized.memory_mb == 1024
    end
  end

  describe "pricing equivalence (#493 — cents identical to destroy-and-recreate)" do
    test "resizing back to the version defaults snapshots the size row's CURRENT compute rate plus the storage axis + a fresh clock" do
      version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)
      InstanceFixtures.local_cluster!()

      # Custom at create (cpu 1 off the 0.5 recommendation — formula
      # priced, no size), then back to the recommendation by resize.
      created =
        Instance.create!(
          %{
            name: "Round trip",
            app_version_id: version.id,
            env_vars: %{},
            cpu_cores: Decimal.new("1")
          },
          actor: user()
        )

      instance = InstanceFixtures.walk_to!(created, :stopped)

      assert instance.size_id == nil

      before = DateTime.utc_now()

      {:ok, resized} =
        Instance.resize(instance, %{cpu_cores: Decimal.new("0.5")}, actor: owner_of(instance))

      after_resize = DateTime.utc_now()

      size = Ash.get!(Size, version.recommended_size_id, authorize?: false)
      storage = Pricing.storage_monthly_cents(resized.storage_gb)

      assert resized.size_id == size.id
      assert resized.grandfathered_monthly_cents == size.monthly_cents + storage
      assert resized.grandfathered_stopped_monthly_cents == storage

      # FRESH clock: a year from THIS resize, not the original create.
      assert DateTime.compare(resized.grandfathered_until, DateTime.shift(before, year: 1)) == :gt

      assert DateTime.compare(resized.grandfathered_until, DateTime.shift(after_resize, year: 1)) ==
               :lt
    end

    test "a resize off the compute defaults prices by the formula, no size" do
      version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)
      InstanceFixtures.local_cluster!()

      created =
        Instance.create!(%{name: "Upsized", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      instance = InstanceFixtures.walk_to!(created, :stopped)

      assert {:ok, resized} =
               Instance.resize(instance, %{memory_mb: 512}, actor: owner_of(instance))

      rates =
        Pricing.price_allocation(%{
          cpu_cores: Decimal.new("0.5"),
          memory_mb: 512,
          storage_gb: resized.storage_gb
        })

      assert resized.size_id == nil
      assert resized.grandfathered_monthly_cents == rates.monthly_cents
      assert resized.grandfathered_stopped_monthly_cents == rates.stopped_monthly_cents
      assert resized.grandfathered_until
    end

    test "a resize to the recommendation on a sizeless version stays unpriced" do
      version = sizeless_version!()
      InstanceFixtures.local_cluster!()

      # Custom at create (the formula prices it fine without a size),
      # then back to the recommendation — where billing never guesses.
      created =
        Instance.create!(
          %{
            name: "Sizeless round trip",
            app_version_id: version.id,
            env_vars: %{},
            cpu_cores: Decimal.new("1")
          },
          actor: user()
        )

      instance = InstanceFixtures.walk_to!(created, :stopped)

      {:ok, resized} =
        Instance.resize(instance, %{cpu_cores: version.default_cpu_cores},
          actor: owner_of(instance)
        )

      assert resized.size_id == nil
      assert resized.grandfathered_monthly_cents == nil
      assert resized.grandfathered_stopped_monthly_cents == nil
      assert resized.grandfathered_until == nil
    end
  end

  describe "policies" do
    test "a non-member is Forbidden" do
      instance = stopped!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.resize(instance, %{memory_mb: 512}, actor: user())
    end

    test "an unfunded wallet is Forbidden (grant-free org)" do
      {_org, owner} = BillingFixtures.grant_free_org!()
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      created =
        Instance.create!(
          %{name: "Unfunded", app_version_id: version.id, env_vars: %{}},
          actor: owner,
          authorize?: false
        )

      instance = InstanceFixtures.walk_to!(created, :stopped)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.resize(instance, %{memory_mb: 512}, actor: owner)
    end
  end

  describe "audit trail append" do
    test "a resize supersedes the open era and appends the new one — exactly one open row" do
      version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)
      InstanceFixtures.local_cluster!()

      created =
        Instance.create!(%{name: "Erased", app_version_id: version.id, env_vars: %{}},
          actor: user()
        )

      instance = InstanceFixtures.walk_to!(created, :stopped)

      assert {:ok, [_era1]} =
               InstanceAllocationSnapshot.in_force(instance.id, authorize?: false)

      assert {:ok, resized} =
               Instance.resize(instance, %{memory_mb: 512}, actor: owner_of(instance))

      rows =
        InstanceAllocationSnapshot
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.Query.sort(created_at: :asc)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 2

      [era1, era2] = rows
      assert era1.superseded_at
      assert era1.memory_mb == 256
      assert is_nil(era1.superseded_at) == false

      # Era 2 mirrors the UPDATED row, effective from the resize instant.
      assert era2.memory_mb == 512
      assert era2.monthly_cents == resized.grandfathered_monthly_cents
      assert era2.superseded_at == nil
      assert DateTime.compare(era2.effective_from, era1.created_at) == :gt

      assert {:ok, [open]} =
               InstanceAllocationSnapshot.in_force(instance.id, authorize?: false)

      assert open.id == era2.id
    end
  end

  # --- helpers --------------------------------------------------------

  # The wallet's usage ledger rows — the settle-happened detector for
  # the refusal tests.
  defp usage_entries(wallet) do
    entries =
      Billing.LedgerEntry
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :usage)
      |> Ash.read!(authorize?: false)

    Enum.map(entries, &%{amount: &1.amount})
  end

  defp user do
    User.create!("resize-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  # The actor for follow-up lifecycle calls, re-derived from the record
  # the way the data model defines ownership: instance → organization →
  # member (the instance_test stance — each fixture call mints its own
  # user/org).
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

  # A fresh instance at the version defaults, walked to :stopped, with
  # no namespace pinned — the cluster re-apply is attribute-only.
  defp stopped!(attrs \\ []) do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    base = %{name: "Resize me", app_version_id: version.id, env_vars: %{}}
    params = Map.merge(base, Map.new(attrs))
    created = Instance.create!(params, actor: user())
    InstanceFixtures.walk_to!(created, :stopped)
  end

  defp running! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    created =
      Instance.create!(%{name: "Running", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    InstanceFixtures.walk_to!(created, :running)
  end

  defp created! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    Instance.create!(%{name: "Pending", app_version_id: version.id, env_vars: %{}},
      actor: user()
    )
  end

  # Ash.Seed! — the create/update actions require a recommended_size;
  # this is the pre-#125 drift shape (the instance_test stance).
  defp sizeless_version! do
    n = System.unique_integer()

    category =
      Category.create!(
        %{name: "Sizeless #{n}", slug: "sizeless-cat-#{n}", description: "test"},
        authorize?: false
      )

    app =
      App.create!(
        %{
          name: "Sizeless #{n}",
          slug: "sizeless-#{n}",
          tagline: "test",
          description: "test",
          category_id: category.id
        },
        authorize?: false
      )

    Ash.Seed.seed!(AppVersion, %{
      version: "1.0.0",
      image: "registry.example.com/app:1.0",
      port: 3000,
      default_cpu_cores: Decimal.new("0.5"),
      default_memory_mb: 512,
      default_storage_gb: 0,
      app_id: app.id
    })
  end
end
