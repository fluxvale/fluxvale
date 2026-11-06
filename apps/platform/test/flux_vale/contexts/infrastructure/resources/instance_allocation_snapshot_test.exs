defmodule FluxVale.Infrastructure.InstanceAllocationSnapshotTest do
  @moduledoc """
  The append-only allocation/pricing audit trail (#493): the create
  path appends era 1 mirroring the row it rode in on. The backfill's
  shape is pinned by the migration's own comment — migrations aren't
  ExUnit-coverable, and no migration test harness is invented for it.
  """

  use FluxVale.DataCase, async: true

  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceAllocationSnapshot
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  test "a create appends exactly one open row mirroring the row" do
    version = InstanceFixtures.app_version!(monthly_cents: 335, stopped_monthly_cents: 40)
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "Audited", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    rows = Ash.read!(InstanceAllocationSnapshot, authorize?: false)
    assert length(rows) == 1

    era = hd(rows)

    assert era.instance_id == instance.id
    assert era.cpu_cores == instance.cpu_cores
    assert era.memory_mb == instance.memory_mb
    assert era.storage_gb == instance.storage_gb
    assert era.size_id == instance.size_id
    assert era.monthly_cents == 335
    assert era.stopped_monthly_cents == 40
    # Era 1 began when the row was born.
    assert era.effective_from == instance.created_at
    # nil = in force.
    assert era.superseded_at == nil
  end

  test "a custom-allocation create snapshots the formula pricing, no size" do
    version = InstanceFixtures.app_version!(monthly_cents: 335, stopped_monthly_cents: 40)
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{
          name: "Custom audited",
          app_version_id: version.id,
          env_vars: %{},
          cpu_cores: Decimal.new("1"),
          memory_mb: 512,
          storage_gb: 10
        },
        actor: user()
      )

    era = hd(Ash.read!(InstanceAllocationSnapshot, authorize?: false))

    assert era.size_id == nil
    assert era.monthly_cents == instance.grandfathered_monthly_cents
    assert era.stopped_monthly_cents == instance.grandfathered_stopped_monthly_cents
  end

  test "an unpriced create (sizeless version at the recommendation) records nulls — billing never guesses" do
    # Ash.Seed! — the only way to produce a sizeless AppVersion: the
    # create/update actions require a recommended_size (pre-#125 drift
    # rows look exactly like this; the instance_test stance).
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

    version =
      Ash.Seed.seed!(AppVersion, %{
        version: "1.0.0",
        image: "registry.example.com/app:1.0",
        port: 3000,
        default_cpu_cores: Decimal.new("0.5"),
        default_memory_mb: 512,
        default_storage_gb: 10,
        app_id: app.id
      })

    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "Unpriced audited", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    era = hd(Ash.read!(InstanceAllocationSnapshot, authorize?: false))

    # Audit truth mirrors the row: unpriced era, real allocation.
    assert era.size_id == nil
    assert era.monthly_cents == nil
    assert era.stopped_monthly_cents == nil
    assert era.memory_mb == instance.memory_mb
  end

  test "the in_force read returns the open era only; supersede closes it" do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(
        %{name: "Era'd", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

    assert {:ok, [era]} =
             InstanceAllocationSnapshot.in_force(instance.id, authorize?: false)

    # The audit trail is system-only — a member cannot drive it.
    assert {:error, %Ash.Error.Forbidden{}} =
             InstanceAllocationSnapshot.in_force(instance.id, actor: user())

    now = DateTime.utc_now()

    InstanceAllocationSnapshot.supersede!(era, %{superseded_at: now}, authorize?: false)

    assert {:ok, []} = InstanceAllocationSnapshot.in_force(instance.id, authorize?: false)

    era = Ash.get!(InstanceAllocationSnapshot, era.id, authorize?: false)
    assert era.superseded_at == now
  end

  defp user do
    User.create!("era-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end
end
