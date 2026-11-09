defmodule FluxVale.Infrastructure.UmamiTakeoverTest do
  @moduledoc false

  # The OQ #3 takeover against the REAL seeded rows (#612 S4): the
  # S2/S3 machinery was pinned against fabricated versions; this module
  # pins it against the shipped Umami pair — the bundled "3.4.1-bundled"
  # row that owns DATABASE_URL, and the pinned BYO "3.4.1" row that
  # still takes it. Never-retconned is pinned in both directions.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Catalog.App
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Types.BackingServiceSnapshot
  alias FluxVale.Seeds
  alias FluxVale.TestSupport.InstanceFixtures

  # The deploy trigger fires under Oban's inline testing mode; the k8s
  # surface is stubbed wherever the create path reaches it.
  setup do
    stub_k8s()

    assert :ok == Seeds.seed_pricing!()
    assert :ok == Seeds.seed_catalog!()
    InstanceFixtures.local_cluster!()

    versions =
      "umami"
      |> App.get_by_slug!(authorize?: false)
      |> Ash.load!([app_versions: :recommended_size], authorize?: false)
      |> Map.fetch!(:app_versions)

    %{
      bundled: Enum.find(versions, &(&1.version == "3.4.1-bundled")),
      byo: Enum.find(versions, &(&1.version == "3.4.1"))
    }
  end

  describe "the bundled row owns DATABASE_URL (D6, the real seeds row)" do
    test "a user value naming it is rejected loudly at create", %{bundled: bundled} do
      crafted =
        Instance.create(
          %{
            name: "Takeover craft",
            app_version_id: bundled.id,
            env_vars: %{"DATABASE_URL" => "postgresql://evil:evil@evil:5432/evil"}
          },
          actor: user()
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} = crafted

      assert Enum.any?(
               errors,
               &(&1.message =~ "bundled backing service" and &1.message =~ "DATABASE_URL")
             )
    end

    test "create without it snapshots the platform postgres from the registry", %{
      bundled: bundled
    } do
      instance = bundled_instance(bundled)

      # The snapshot (D2): the registry's exact pin frozen on the row —
      # read from the same config the derive resolves against.
      pg = Application.fetch_env!(:flux_vale, :backing_services)[:postgres]["18"]

      assert [%BackingServiceSnapshot{} = snapshot] = instance.backing_services
      assert snapshot.kind == :postgres
      assert snapshot.version == "18"
      assert snapshot.url_env == "DATABASE_URL"
      assert snapshot.image == pg.image
      assert snapshot.memory_mb == pg.memory_mb

      # The floors held at the version's honest defaults (medium) and
      # the platform's key never entered user env — the deploy composes
      # it from the backing Secret, above every layer.
      assert Decimal.equal?(instance.cpu_cores, Decimal.new("0.5"))
      assert instance.memory_mb == 1024
      assert instance.storage_gb == 10
      refute Map.has_key?(instance.env_vars, "DATABASE_URL")
    end

    test "the carve renders the app at allocation minus the PG share exactly", %{bundled: bundled} do
      instance = bundled_instance(bundled)
      spec = InstanceK8s.deployment_spec(instance, %{"APP_SECRET" => "x"})

      # D1's arithmetic on the real row's defaults: 0.5 − 0.10 CPU and
      # 1024 − 256 MB for the app; the pod's total stays the purchased
      # allocation. Decimal end-to-end (the quota's own rule).
      assert Decimal.equal?(spec.cpu, Decimal.new("0.4"))
      assert spec.memory == 768

      assert [%{kind: :postgres, image: image, cpu: share, memory_mb: 256}] =
               spec.backing_services

      assert image == Application.fetch_env!(:flux_vale, :backing_services)[:postgres]["18"].image
      assert Decimal.equal?(share, Decimal.new("0.1"))
    end
  end

  describe "the pinned BYO row is never retconned (both directions)" do
    test "a new instance on the old row still brings its own DATABASE_URL", %{byo: byo} do
      instance =
        Instance.create!(
          %{
            name: "BYO still ships",
            app_version_id: byo.id,
            env_vars: %{
              "DATABASE_URL" => "postgresql://owner:pw@far.example:5432/analytics",
              "APP_SECRET" => "takeover-test-app-secret-placeholder"
            }
          },
          actor: user()
        )

      # Direction 1 — the old row's contract stands: the user value is
      # the instance's stored truth, no services declared, nothing
      # composed over it at deploy.
      assert instance.backing_services == []

      assert instance.env_vars["DATABASE_URL"] ==
               "postgresql://owner:pw@far.example:5432/analytics"

      spec = InstanceK8s.deployment_spec(instance, instance.env_vars)

      # Direction 2 — rendering an old-row instance carves nothing: the
      # app keeps the whole allocation, and no backing init container
      # exists to shadow the user's database.
      assert Decimal.equal?(spec.cpu, Decimal.new("0.25"))
      assert spec.memory == 512
      refute Map.has_key?(spec, :backing_services)
    end

    test "the old row's required-input contract still demands its secrets", %{byo: byo} do
      crafted =
        Instance.create(
          %{name: "BYO still demands", app_version_id: byo.id, env_vars: %{}},
          actor: user()
        )

      assert {:error, %Ash.Error.Invalid{errors: errors}} = crafted

      # Both required inputs still gate the old row — the BYO shape
      # ships unchanged, not quietly loosened by its bundled sibling.
      assert Enum.any?(errors, &(&1.message =~ "APP_SECRET is required"))
      assert Enum.any?(errors, &(&1.message =~ "DATABASE_URL is required"))
    end
  end

  defp bundled_instance(bundled) do
    Instance.create!(
      %{
        name: "Bundled #{System.unique_integer()}",
        app_version_id: bundled.id,
        env_vars: %{"APP_SECRET" => "takeover-test-app-secret-placeholder"}
      },
      actor: user()
    )
  end

  defp user do
    User.create!("takeover-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp stub_k8s do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

    stub(Namespace, :create, fn _kc, _ns, _spec -> {:ok, %{}} end)
    stub(RoleBinding, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(ResourceQuota, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(NetworkPolicy, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(PersistentVolumeClaim, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Secret, :create, fn _kc, _ns, _n, _data -> {:ok, %{}} end)
    stub(Deployment, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Service, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Ingress, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, _ns, _n, _spec -> {:ok, %{}} end)
    stub(Deployment, :scale, fn _kc, _ns, _n, _r -> {:ok, %{}} end)
  end
end
