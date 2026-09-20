defmodule FluxVale.Clients.K8s.Resources.DeploymentTest do
  use ExUnit.Case, async: true

  alias FluxVale.Clients.K8s.Resources.Deployment

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
end
