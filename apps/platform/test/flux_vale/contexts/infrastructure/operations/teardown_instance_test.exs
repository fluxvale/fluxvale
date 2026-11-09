defmodule FluxVale.Infrastructure.Operations.TeardownInstanceTest do
  @moduledoc false

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Ingress
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
  alias FluxVale.Infrastructure.Operations.TeardownInstance
  alias FluxVale.TestSupport.InstanceFixtures

  defp user do
    User.create!("teardown-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
  end

  defp deleting! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance =
      Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

    {:ok, deleting} = InstanceK8s.update_status(instance, :deleting, "Tearing down...")

    InstanceFixtures.pin!(deleting, namespace: "fluxvale-app-#{instance.id}")
  end

  defp stub_kubeconfig do
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
  end

  defp stub_deletes do
    stub(Ingress, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Service, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Deployment, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Secret, :delete, fn _kc, _ns, _n -> :ok end)
    stub(PersistentVolumeClaim, :delete, fn _kc, _ns, _n -> :ok end)
    stub(NetworkPolicy, :delete, fn _kc, _ns, _n -> :ok end)
    stub(ResourceQuota, :delete, fn _kc, _ns, _n -> :ok end)
    stub(RoleBinding, :delete, fn _kc, _ns, _n -> :ok end)
    stub(Namespace, :delete, fn _kc, _n -> :ok end)
  end

  describe "call/1" do
    test "deletes every resource then the namespace, then hard-deletes the row" do
      stub_kubeconfig()
      instance = deleting!()
      ns = "fluxvale-app-#{instance.id}"

      stub_deletes()

      expect(Namespace, :delete, fn _kc, ^ns -> :ok end)

      assert {:ok, returned} = TeardownInstance.call(instance)
      assert returned.id == instance.id

      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "not_found deletes are tolerated (idempotent retries)" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Deployment, :delete, fn _kc, _ns, _n ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      # The namespace delete too — a retried teardown races namespace GC.
      expect(Namespace, :delete, fn _kc, _ns ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, _deleted} = TeardownInstance.call(instance)
    end

    test "the backup-config Secret is deleted (#222)" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Secret, :delete, fn _kc, _ns, "backup-config" -> :ok end)

      assert {:ok, _deleted} = TeardownInstance.call(instance)
    end

    test "a missing backup-config Secret is not_found-tolerant (pre-#222 namespaces)" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Secret, :delete, fn _kc, _ns, "backup-config" ->
        {:error, Error.from_response({:ok, %{status: 404, body: %{}}})}
      end)

      assert {:ok, _deleted} = TeardownInstance.call(instance)
    end

    test "a namespace-delete failure surfaces for Oban to retry" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Namespace, :delete, fn _kc, _ns ->
        {:error, Error.from_response({:ok, %{status: 500, body: %{}}})}
      end)

      assert {:error, %Error{reason: :api_error}} = TeardownInstance.call(instance)
    end

    test "a real K8s failure returns :error for Oban to retry; the row stays :deleting" do
      stub_kubeconfig()
      instance = deleting!()

      stub_deletes()

      expect(Ingress, :delete, fn _kc, _ns, _n ->
        {:error, Error.connection_error("cluster on fire")}
      end)

      assert {:error, %Error{}} = TeardownInstance.call(instance)

      assert {:ok, _row} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "a kubeconfig failure returns :error without touching the row" do
      stub(K8s, :kubeconfig, fn nil -> {:error, Error.connection_error("no SA files")} end)

      instance = deleting!()

      assert {:error, %Error{}} = TeardownInstance.call(instance)

      assert {:ok, _row} = Instance.get_by_id(instance.id, authorize?: false)
    end

    test "a non-:deleting instance is a no-op (superseded retry)" do
      version = InstanceFixtures.app_version!()
      InstanceFixtures.local_cluster!()

      instance =
        Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}}, actor: user())

      assert {:ok, returned} = TeardownInstance.call(instance)
      assert returned.id == instance.id
    end
  end

  # #597 D6: the wiring's PocketID client is deleted best-effort
  # BEFORE the wiring row cascades away with the instance row — and
  # a refused delete never blocks the teardown (the client stays
  # visible in PocketID's admin).
  describe "the PocketID client cleanup (D6)" do
    setup do
      stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
      :ok
    end

    defp deleting_with_wiring! do
      actor = user()

      pocket_id_version =
        InstanceFixtures.app_version!(app_slug: "pocket-id", configurable_env_vars: %{})

      InstanceFixtures.local_cluster!()

      pocket_id =
        pocket_id_version
        |> InstanceFixtures.instance!(actor)
        |> InstanceFixtures.walk_to!(:running)
        |> InstanceFixtures.pin!(namespace: "ns-pid")

      FluxVale.Infrastructure.PocketIdCustody.record!(
        %{
          organization_id: pocket_id.organization_id,
          instance_id: pocket_id.id,
          api_key_secret_ref: "fluxvale-pocketid-custody-#{pocket_id.id}",
          verified_at: DateTime.utc_now()
        },
        authorize?: false
      )

      stub(Secret, :get_data, fn _kc, _ns, _ref ->
        {:ok, %{"POCKETID_API_KEY" => "held-key-not-real"}}
      end)

      version = InstanceFixtures.app_version!()

      app =
        Instance.create!(%{name: "App", app_version_id: version.id, env_vars: %{}},
          actor: actor
        )

      {:ok, deleting} = InstanceK8s.update_status(app, :deleting, "Tearing down...")
      app = InstanceFixtures.pin!(deleting, namespace: "fluxvale-app-#{app.id}")

      FluxVale.Infrastructure.PocketIdWiring.record!(
        %{
          instance_id: app.id,
          pocket_id_instance_id: pocket_id.id,
          pocket_id_client_id: "client-d6",
          pocket_id_secret_id: "secret-d6"
        },
        authorize?: false
      )

      {app, pocket_id}
    end

    test "deletes the PocketID client before the row cascades away" do
      stub_deletes()
      {app, pocket_id} = deleting_with_wiring!()

      expect(FluxVale.Infrastructure.PocketId.ApiClient, :delete_client, fn url,
                                                                            _key,
                                                                            "client-d6" ->
        send(self(), :client_deleted)
        assert url =~ pocket_id.slug
        :ok
      end)

      assert {:ok, _} = TeardownInstance.call(app)
      assert_received :client_deleted
      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(app.id, authorize?: false)
    end

    test "a refused client delete never blocks the teardown" do
      stub_deletes()
      {app, _pocket_id} = deleting_with_wiring!()

      stub(FluxVale.Infrastructure.PocketId.ApiClient, :delete_client, fn _u, _k, _c ->
        {:error, :unreachable}
      end)

      assert {:ok, _} = TeardownInstance.call(app)
      assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(app.id, authorize?: false)
    end

    test "no wiring is plain silence — nothing extra is called" do
      stub_deletes()
      instance = deleting_with_wiring!() |> then(fn {app, _pid} -> app end)

      FluxVale.Infrastructure.PocketIdWiring.get_by_instance!(instance.id, authorize?: false)
      |> FluxVale.Infrastructure.PocketIdWiring.replace(authorize?: false)

      # No ApiClient stub: Mimic rejects any call — the teardown must
      # not reach for the PocketID without a wiring.
      assert {:ok, _} = TeardownInstance.call(instance)
    end
  end
end
