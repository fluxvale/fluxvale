defmodule FluxVale.Infrastructure.InstanceIntegrationTest do
  @moduledoc """
  Local-cluster integration for the Instance lifecycle (ADR-0020: the
  cluster is for k8s-touching integration work; `mix test` stays native).

  Excluded by default — run explicitly against a live `tilt up` stack:

      FLUXVALE_K8S_KUBECONFIG=~/.config/k3d/kubeconfig-fluxvale.yaml \
        mix test --only k8s test/flux_vale/contexts/infrastructure/instance_integration_test.exs

  No cluster running (or no k3d kubeconfig) → these tests flunk with a
  pointer, they never silently skip. CI never runs them (no k3d there —
  #75 settles where the suite runs).
  """

  use FluxVale.DataCase, async: false

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Namespace
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.ResourceQuota
  alias FluxVale.Clients.K8s.Resources.RoleBinding
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ReconcileInstance
  alias FluxVale.TestSupport.InstanceFixtures

  @moduletag :k8s

  @ready_timeout 120_000

  # Small, fast-pulling image that serves HTTP on :80 — the lifecycle is
  # under test, not the app (Forgejo itself is the #75 e2e vehicle).
  @tiny_image "traefik/whoami:v1.10"

  defp kubeconfig do
    path =
      System.get_env("FLUXVALE_K8S_KUBECONFIG") ||
        Path.expand("~/.config/k3d/kubeconfig-fluxvale.yaml")

    unless File.exists?(path) do
      flunk("no kubeconfig at #{path} — start the stack (tilt up) or set FLUXVALE_K8S_KUBECONFIG")
    end

    {:ok, kubeconfig} = K8s.kubeconfig(path)
    kubeconfig
  end

  defp cluster!(kubeconfig_path) do
    case Cluster.get_by_name("integration", authorize?: false) do
      {:ok, cluster} ->
        cluster

      {:error, _not_found} ->
        Cluster.create!(%{name: "integration", kubeconfig_ref: kubeconfig_path},
          authorize?: false
        )
    end
  end

  # Cluster resolution pins THE single cluster row — the integration path
  # runs with exactly this one present.
  defp clear_other_clusters!(keep_id) do
    {:ok, clusters} = Ash.read(Cluster, authorize?: false)

    for cluster <- clusters, cluster.id != keep_id do
      Ash.destroy!(cluster, authorize?: false)
    end
  end

  defp instance!(cluster) do
    version =
      InstanceFixtures.app_version!(
        image: @tiny_image,
        port: 80,
        healthcheck_path: "/",
        default_storage_gb: 1,
        default_env_vars: %{"WHOAMI_DEFAULT" => "set-by-catalog"}
      )

    clear_other_clusters!(cluster.id)

    user =
      User.create!("integration-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)

    Instance.create!(
      %{
        name: "Integration whoami",
        app_version_id: version.id,
        env_vars: %{"WHOAMI_USER" => "integration"}
      },
      actor: user
    )
  end

  defp wait_until_ready!(kubeconfig, namespace) do
    case Deployment.wait_for_ready(kubeconfig, namespace, "app", timeout_ms: @ready_timeout) do
      :ok ->
        :ok

      {:error, error} ->
        flunk("deployment #{namespace}/app never became ready: #{Exception.message(error)}")
    end
  end

  defp reload!(instance) do
    Instance.get_by_id!(instance.id, authorize?: false)
  end

  test "the full lifecycle: deploy → running → stop → start → teardown" do
    kubeconfig_path =
      System.get_env("FLUXVALE_K8S_KUBECONFIG") ||
        Path.expand("~/.config/k3d/kubeconfig-fluxvale.yaml")

    kubeconfig = kubeconfig()
    cluster = cluster!(kubeconfig_path)
    instance = instance!(cluster)

    on_exit(fn ->
      # Cluster-level cleanup, outside the sandbox transaction: whatever
      # the test left behind, the namespace must go.
      namespace = "fluxvale-app-#{instance.id}"

      case Namespace.get(kubeconfig(), namespace) do
        {:ok, _ns} -> Namespace.delete(kubeconfig(), namespace)
        {:error, _err} -> :ok
      end
    end)

    # 1. Deploy: pending → deploying → starting, namespace materialized
    assert {:ok, _deploying} = Instance.deploy(instance, authorize?: false)
    namespace = "fluxvale-app-#{instance.id}"

    # 2. Every product primitive lands in the namespace
    assert {:ok, _quota} = ResourceQuota.get(kubeconfig, namespace, "app-quota")
    assert {:ok, _policy} = NetworkPolicy.get(kubeconfig, namespace, "default-deny-ingress")
    assert {:ok, _binding} = RoleBinding.get(kubeconfig, namespace, "fluxvale-platform")

    assert {:ok, secret} = Secret.get(kubeconfig, namespace, "app-env")
    assert secret["data"]["WHOAMI_USER"] == "aW50ZWdyYXRpb24="

    # 3. Readiness → the reconciler is the writer of :running
    wait_until_ready!(kubeconfig, namespace)

    first_run = reload!(instance)

    assert {:ok, running} = ReconcileInstance.call(first_run)
    assert running.status == :running
    assert running.running_since

    # 4. Stop/start ride the scale path
    assert {:ok, stopped} = Instance.stop(running, authorize?: false)
    assert stopped.status == :stopped
    assert stopped.running_since == nil

    assert {:ok, started} = Instance.start(stopped, authorize?: false)
    assert started.status == :starting

    wait_until_ready!(kubeconfig, namespace)
    reloaded = reload!(instance)

    assert {:ok, running_again} = ReconcileInstance.call(reloaded)
    assert running_again.status == :running

    # 5. Teardown removes everything and hard-deletes the row
    assert {:ok, _deleting} = Instance.delete(instance.id, authorize?: false)
    assert {:error, %Ash.Error.Invalid{}} = Instance.get_by_id(instance.id, authorize?: false)

    assert_eventually(fn ->
      match?({:error, %K8s.Error{reason: :not_found}}, Namespace.get(kubeconfig(), namespace))
    end)
  end

  # Polling an external system, not a process — sleep is the tool.
  defp assert_eventually(fun, attempts_left \\ 30) do
    if fun.() do
      assert true
    else
      if attempts_left == 0 do
        flunk("condition never became true within the polling window")
      end

      Process.sleep(1_000)
      assert_eventually(fun, attempts_left - 1)
    end
  end
end
