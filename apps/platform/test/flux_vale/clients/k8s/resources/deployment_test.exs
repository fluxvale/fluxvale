defmodule FluxVale.Clients.K8s.Resources.DeploymentTest do
  use ExUnit.Case, async: true
  use Mimic

  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment

  setup do
    stub(Kubereq, :attach, fn req, _opts -> req end)
    :ok
  end

  defp base_spec do
    %{image: "codeberg.org/forgejo/forgejo:13", port: 3000}
  end

  defp container(manifest),
    do: get_in(manifest, ["spec", "template", "spec", "containers", Access.at(0)])

  describe "build_manifest/3 — defaults" do
    test "cpu 0.5 / memory 256Mi / 1 replica, limits at 2x requests" do
      manifest = Deployment.build_manifest("fluxvale-app-1", "forgejo", base_spec())

      assert get_in(manifest, ["spec", "replicas"]) == 1
      assert container(manifest)["image"] == "codeberg.org/forgejo/forgejo:13"
      assert container(manifest)["ports"] == [%{"containerPort" => 3000}]

      assert container(manifest)["resources"]["requests"] == %{
               "cpu" => "0.5",
               "memory" => "256Mi"
             }

      assert container(manifest)["resources"]["limits"] == %{"cpu" => "1.0", "memory" => "512Mi"}
    end

    test "explicit cpu/memory/replicas override defaults" do
      spec =
        base_spec()
        |> Map.put(:cpu, 0.25)
        |> Map.put(:memory, 512)
        |> Map.put(:replicas, 3)

      manifest = Deployment.build_manifest("ns", "app", spec)

      assert get_in(manifest, ["spec", "replicas"]) == 3

      assert container(manifest)["resources"]["requests"] == %{
               "cpu" => "0.25",
               "memory" => "512Mi"
             }

      assert container(manifest)["resources"]["limits"] == %{"cpu" => "0.5", "memory" => "1024Mi"}
    end

    test "env map becomes env var entries with stringified values" do
      manifest =
        Deployment.build_manifest(
          "ns",
          "app",
          Map.put(base_spec(), :env, %{"K" => "v", "N" => 42})
        )

      assert container(manifest)["env"] == [
               %{"name" => "K", "value" => "v"},
               %{"name" => "N", "value" => "42"}
             ]
    end

    test "probes target the container port" do
      manifest = Deployment.build_manifest("ns", "app", base_spec())

      assert container(manifest)["readinessProbe"]["httpGet"]["port"] == 3000
      assert container(manifest)["startupProbe"]["httpGet"]["port"] == 3000
      assert container(manifest)["startupProbe"]["failureThreshold"] == 18
    end

    test "labels and selector agree for rollout matching" do
      manifest = Deployment.build_manifest("ns", "app", base_spec())

      assert get_in(manifest, ["spec", "selector", "matchLabels"]) == %{
               "app.kubernetes.io/name" => "app"
             }

      assert get_in(manifest, ["spec", "template", "metadata", "labels"]) == %{
               "app.kubernetes.io/managed-by" => "fluxvale",
               "app.kubernetes.io/name" => "app"
             }
    end
  end

  describe "build_manifest/3 — storage" do
    test "mounts the PVC when storage_mount + pvc_name are set" do
      spec =
        base_spec()
        |> Map.put(:storage_mount, "/data")
        |> Map.put(:pvc_name, "forgejo-data")

      manifest = Deployment.build_manifest("ns", "forgejo", spec)

      assert container(manifest)["volumeMounts"] == [
               %{"name" => "storage", "mountPath" => "/data"}
             ]

      assert get_in(manifest, ["spec", "template", "spec", "volumes"]) == [
               %{"name" => "storage", "persistentVolumeClaim" => %{"claimName" => "forgejo-data"}}
             ]
    end

    test "no mount or volume without storage config" do
      manifest = Deployment.build_manifest("ns", "app", base_spec())
      pod_spec = get_in(manifest, ["spec", "template", "spec"])
      app_container = container(manifest)

      refute Map.has_key?(app_container, "volumeMounts")
      refute Map.has_key?(pod_spec, "volumes")
    end
  end

  describe "ready?/1 — the generation-gated readiness predicate" do
    defp status_map(overrides) do
      Map.merge(
        %{
          replicas: 2,
          actual_replicas: 2,
          updated: 2,
          available: 2,
          ready: 2,
          generation: 3,
          observed_generation: 3,
          conditions: []
        },
        overrides
      )
    end

    test "fully rolled-out deployment is ready" do
      status = status_map(%{})
      assert Deployment.ready?(status)
    end

    test "old-generation pods ready do not count — controller hasn't observed the new generation" do
      status = status_map(%{observed_generation: 2, generation: 3})
      refute Deployment.ready?(status)
    end

    test "generation caught up but rollout incomplete (updated < desired)" do
      status = status_map(%{updated: 1})
      refute Deployment.ready?(status)
    end

    test "surge pods (actual > desired) mean still rolling" do
      status = status_map(%{actual_replicas: 3})
      refute Deployment.ready?(status)
    end

    test "ready < desired" do
      status = status_map(%{ready: 1})
      refute Deployment.ready?(status)
    end

    test "scale-to-zero is ready by definition" do
      status = status_map(%{replicas: 0, actual_replicas: 0, updated: 0, ready: 0})
      assert Deployment.ready?(status)
    end

    test "paused deployment: observed stalls below generation — never ready" do
      status = status_map(%{observed_generation: 1, generation: 4})
      refute Deployment.ready?(status)
    end
  end

  defp fetched_deployment do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => "forgejo",
        "namespace" => "fluxvale-app-1",
        "managedFields" => [%{"manager" => "other"}]
      },
      "spec" => %{"replicas" => 1, "template" => %{"metadata" => %{}, "spec" => %{}}}
    }
  end

  defp status_body(ready_replicas, opts \\ []) do
    desired = Keyword.get(opts, :desired, 1)

    %{
      "metadata" => %{"generation" => 3},
      "spec" => %{"replicas" => desired},
      "status" => %{
        "replicas" => ready_replicas,
        "updatedReplicas" => ready_replicas,
        "availableReplicas" => ready_replicas,
        "readyReplicas" => ready_replicas,
        "observedGeneration" => 3
      }
    }
  end

  describe "create/4" do
    test "applies the manifest and returns the 201 body" do
      expect(Kubereq, :apply, fn _req, manifest, field_manager ->
        assert manifest["kind"] == "Deployment"
        assert field_manager == "fluxvale"
        {:ok, %{status: 201, body: %{"kind" => "Deployment"}}}
      end)

      assert {:ok, %{"kind" => "Deployment"}} =
               Deployment.create(%{}, "fluxvale-app-1", "forgejo", base_spec())
    end

    test "200 (already applied) is still ok" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 200, body: :present}} end)

      assert {:ok, :present} =
               Deployment.create(%{}, "fluxvale-app-1", "forgejo", base_spec())
    end

    test "non-2xx maps to an Error" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 422, body: %{"message" => "invalid"}}}
      end)

      assert {:error, %Error{reason: :api_error, status_code: 422}} =
               Deployment.create(%{}, "fluxvale-app-1", "forgejo", base_spec())
    end
  end

  describe "get/3 and status/3" do
    test "404 is :not_found" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Deployment.get(%{}, "fluxvale-app-1", "x")
    end

    test "status builds the replica/generation map with zero defaults" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"metadata" => %{"generation" => 7}}}}
      end)

      assert {:ok, status} = Deployment.status(%{}, "fluxvale-app-1", "x")
      assert status.generation == 7
      assert status.observed_generation == 0
      assert status.ready == 0
      assert status.conditions == []
    end

    test "status errors propagate" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               Deployment.status(%{}, "fluxvale-app-1", "x")
    end
  end

  describe "delete/3" do
    test "200 deletes synchronously" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)

      assert :ok = Deployment.delete(%{}, "fluxvale-app-1", "forgejo")
    end

    test "202 accepts asynchronous deletion" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 202}} end)

      assert :ok = Deployment.delete(%{}, "fluxvale-app-1", "forgejo")
    end

    test "404 is :not_found" do
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} = Deployment.delete(%{}, "ns", "missing")
    end
  end

  describe "scale/4" do
    test "strips managedFields and applies the new replica count" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: fetched_deployment()}}
      end)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["metadata"]["managedFields"] == nil
        assert manifest["spec"]["replicas"] == 3
        {:ok, %{status: 200, body: manifest}}
      end)

      assert {:ok, %{"spec" => %{"replicas" => 3}}} =
               Deployment.scale(%{}, "fluxvale-app-1", "forgejo", 3)
    end

    test "a failed get propagates without applying" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, %Error{reason: :not_found}} =
               Deployment.scale(%{}, "fluxvale-app-1", "forgejo", 3)
    end
  end

  describe "restart/3" do
    test "a failed get propagates without applying" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               Deployment.restart(%{}, "fluxvale-app-1", "forgejo")
    end

    test "sets restartedAt on empty annotations" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: fetched_deployment()}}
      end)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["metadata"]["managedFields"] == nil

        annotations = get_in(manifest, ["spec", "template", "metadata", "annotations"])
        assert Map.has_key?(annotations, "fluxvale.io/restartedAt")

        {:ok, %{status: 200, body: manifest}}
      end)

      assert {:ok, _body} = Deployment.restart(%{}, "fluxvale-app-1", "forgejo")
    end

    test "merges into existing annotations without dropping them" do
      fetched = fetched_deployment()

      deployment =
        put_in(fetched, ["spec", "template", "metadata", "annotations"], %{"keep" => "me"})

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: deployment}} end)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        annotations = get_in(manifest, ["spec", "template", "metadata", "annotations"])
        assert annotations["keep"] == "me"
        assert Map.has_key?(annotations, "fluxvale.io/restartedAt")
        {:ok, %{status: 200, body: manifest}}
      end)

      assert {:ok, _body} = Deployment.restart(%{}, "fluxvale-app-1", "forgejo")
    end
  end

  describe "wait_for_ready/4" do
    test ":ok when the status map is ready" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: status_body(1)}}
      end)

      assert :ok = Deployment.wait_for_ready(%{}, "ns", "x", timeout_ms: 10)
    end

    test "retries past a not-ready poll, then succeeds" do
      # Mimic expects queue in call order: first poll not ready, second ready
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: status_body(0)}} end)

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: status_body(1)}} end)

      assert :ok = Deployment.wait_for_ready(%{}, "ns", "x", timeout_ms: 500, poll_interval_ms: 1)
    end

    test "times out with a structured timeout error" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: status_body(0)}} end)

      assert {:error, %Error{reason: :timeout, message: msg}} =
               Deployment.wait_for_ready(%{}, "ns", "x", timeout_ms: 0, poll_interval_ms: 1)

      assert msg =~ "Timeout waiting for deployment ns/x to be ready"
    end

    test "status errors propagate immediately" do
      expect(Kubereq, :get, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, %Error{reason: :connection_error}} =
               Deployment.wait_for_ready(%{}, "ns", "x", timeout_ms: 10)
    end
  end

  describe "upsert/4" do
    test "delegates to create (SSA idempotence)" do
      expect(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 201, body: :created}} end)

      assert {:ok, :created} = Deployment.upsert(%{}, "ns", "app", base_spec())
    end
  end

  test "attaches the request with the right api_version/kind (routing pin)" do
    expect(Kubereq, :attach, fn _req, opts ->
      assert opts[:api_version] == "apps/v1"
      assert opts[:kind] == "Deployment"
      :pinned_req
    end)

    stub(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)
    Deployment.get(%{}, "ns", "x")
  end
end
