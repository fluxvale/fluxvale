defmodule FluxVale.ReleaseTest do
  @moduledoc """
  The release DB tasks (`FluxVale.Release.migrate/0`, `seed/0`,
  `ensure_cluster/0`, `label_instance_namespaces/0`). The functions run
  unchanged under ExUnit — `with_repo/2` reuses the already-started
  test repo — so the suite exercises the real code and only the no-Mix
  release *environment* stays untested (#98).
  """

  use FluxVale.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  test "migrate/0 is a no-op when all migrations are applied" do
    assert :ok = FluxVale.Release.migrate()
  end

  test "seed/0 brings up the admin + catalog" do
    assert :ok = FluxVale.Release.seed()

    assert %{platform_role: :admin} =
             User.get_by_email!("admin@fluxvale.com", authorize?: false)
  end

  # CLUSTER_NAME is VM-global but read only by ensure_cluster/0, so no
  # async test races these.
  describe "ensure_cluster/0" do
    setup do
      original = System.get_env("CLUSTER_NAME")

      on_exit(fn ->
        case original do
          nil -> System.delete_env("CLUSTER_NAME")
          value -> System.put_env("CLUSTER_NAME", value)
        end
      end)

      :ok
    end

    test "raises when CLUSTER_NAME is unset or empty" do
      System.delete_env("CLUSTER_NAME")

      assert_raise ArgumentError, ~r/CLUSTER_NAME/, fn ->
        FluxVale.Release.ensure_cluster()
      end

      System.put_env("CLUSTER_NAME", "")

      assert_raise ArgumentError, ~r/CLUSTER_NAME/, fn ->
        FluxVale.Release.ensure_cluster()
      end
    end

    test "creates the row by name with a null kubeconfig_ref" do
      System.put_env("CLUSTER_NAME", "bringup-test-01")

      assert :ok = FluxVale.Release.ensure_cluster()

      assert {:ok, %{kubeconfig_ref: nil}} =
               Cluster.get_by_name("bringup-test-01", authorize?: false)
    end

    test "never converges an existing row" do
      existing =
        Cluster.create!(%{name: "bringup-drift-01", kubeconfig_ref: "secrets/ref"},
          authorize?: false
        )

      System.put_env("CLUSTER_NAME", "bringup-drift-01")

      assert :ok = FluxVale.Release.ensure_cluster()

      assert {:ok, %{id: id, kubeconfig_ref: "secrets/ref"}} =
               Cluster.get_by_name("bringup-drift-01", authorize?: false)

      assert id == existing.id
    end

    test "a second run with the same name is idempotent — one row, no error" do
      System.put_env("CLUSTER_NAME", "bringup-twice-01")

      assert :ok = FluxVale.Release.ensure_cluster()
      assert :ok = FluxVale.Release.ensure_cluster()

      assert {:ok, clusters} = Ash.read(Cluster, authorize?: false)
      assert [%{name: "bringup-twice-01"}] = clusters
    end

    # The deploy-breaking edge (#172): the probe is by all-rows, not
    # by-name, so a re-run with a different CLUSTER_NAME can't add the
    # second row ResolveCluster rejects.
    test "refuses a second row under a different name" do
      Cluster.create!(%{name: "bringup-first-01"}, authorize?: false)
      System.put_env("CLUSTER_NAME", "bringup-typo-01")

      assert_raise RuntimeError, ~r/already exists, not "bringup-typo-01"/, fn ->
        FluxVale.Release.ensure_cluster()
      end

      assert {:ok, clusters} = Ash.read(Cluster, authorize?: false)
      assert [%{name: "bringup-first-01"}] = clusters
    end

    test "raises loudly when the table is already in the many-rows state" do
      Cluster.create!(%{name: "bringup-a-01"}, authorize?: false)
      Cluster.create!(%{name: "bringup-b-01"}, authorize?: false)
      System.put_env("CLUSTER_NAME", "bringup-a-01")

      assert_raise RuntimeError, ~r/2 cluster rows already exist/, fn ->
        FluxVale.Release.ensure_cluster()
      end
    end

    # #172 review: the create runs through `Ash.create!` so a bad name
    # still raises the typed, actionable error instead of an opaque
    # MatchError. CLUSTER_NAME is unvalidated operator input.
    test "a non-DNS name raises the typed Ash error, not a MatchError" do
      System.put_env("CLUSTER_NAME", "Bad_Name")

      assert_raise Ash.Error.Invalid, fn -> FluxVale.Release.ensure_cluster() end

      assert {:ok, []} = Ash.read(Cluster, authorize?: false)
    end
  end

  # The pre-#196 backfill (#196): the orphan sweep deletes only
  # own-env-labeled namespaces, so every namespace deployed before the
  # label existed must be claimed once by the env that owns its row.
  describe "label_instance_namespaces/0" do
    setup do
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      {:ok, version: version}
    end

    test "stamps this env's label on every row-backed live namespace" do
      instance = row_backed_instance!()

      ns = "fluxvale-app-#{instance.id}"

      expect(Namespace, :exists?, fn _kc, ^ns -> {:ok, true} end)

      expect(Namespace, :create, fn _kc, ^ns, spec ->
        # The test env's :platform_env is the config.exs default —
        # mutating it would race every async deploy test's assertion.
        assert spec == %{labels: %{"fluxvale.io/platform-env" => "local"}}
        {:ok, %{}}
      end)

      assert :ok = FluxVale.Release.label_instance_namespaces()
    end

    test "a namespace that already 404s is skipped, not failed — the sweeper's :lost lane owns it" do
      instance = row_backed_instance!()
      ns = "fluxvale-app-#{instance.id}"

      expect(Namespace, :exists?, fn _kc, ^ns -> {:ok, false} end)

      assert :ok = FluxVale.Release.label_instance_namespaces()

      # No create ran (verify_on_exit!), and the row itself is
      # untouched — a labeling pass never flips statuses.
      assert {:ok, %{status: :running}} =
               Ash.get(Instance, instance.id, authorize?: false)
    end

    test "nil-namespace and :deleting rows never touch the cluster" do
      version = InstanceFixtures.app_version!()

      # pending: nothing deployed, namespace nil.
      Instance.create!(%{name: "Never deployed", app_version_id: version.id, env_vars: %{}},
        actor: user()
      )

      # deleting: the namespace is Terminating, the sweep skips it too.
      deleting = row_backed_instance!()
      {:ok, deleting_row} = InstanceK8s.update_status(deleting, :deleting, "tearing down")

      assert :ok = FluxVale.Release.label_instance_namespaces()

      assert Mimic.calls(&Namespace.exists?/2) == []
      assert deleting_row.status == :deleting
    end

    test "an unreadable namespace raises after the pass — operator re-runs, idempotent" do
      row_backed_instance!()

      expect(Namespace, :exists?, fn _kc, _ns ->
        {:error, Error.connection_error("api unreachable")}
      end)

      assert_raise RuntimeError, ~r/1 namespace\(s\) failed to label/, fn ->
        FluxVale.Release.label_instance_namespaces()
      end
    end
  end

  defp row_backed_instance! do
    instance =
      Instance.create!(
        %{name: "Claimed app", app_version_id: version_fixture_id(), env_vars: %{}},
        actor: user()
      )

    running = InstanceFixtures.walk_to!(instance, :running)

    # The deploy action pins the namespace; update_status can't (write-once).
    InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{instance.id}")
  end

  # A fresh version per instance — the catalog create is cheap, and a
  # shared row would couple every describe's fixtures.
  defp version_fixture_id do
    InstanceFixtures.app_version!().id
  end

  defp user do
    User.create!("release-label-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end
end
