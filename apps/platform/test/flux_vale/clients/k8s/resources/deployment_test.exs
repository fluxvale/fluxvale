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

      assert container(manifest)["resources"]["limits"] == %{"cpu" => "1", "memory" => "512Mi"}
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

    test "a volume-mounting pod carries a pod-level fsGroup (#609)" do
      # Docmost is the first non-root entry that WRITES to its volume
      # (UID 1000, uploads under /app/data/storage): a local-path
      # volume lands root-owned, so without a supplemental gid every
      # upload EACCES — the local stack's MinIO manifest documents the
      # same fix. The grant is pod-level and uid-agnostic: the kubelet
      # gives every container the group and group-write on the volume.
      spec =
        base_spec()
        |> Map.put(:storage_mount, "/app/data/storage")
        |> Map.put(:pvc_name, "app-data")

      manifest = Deployment.build_manifest("ns", "docmost", spec)

      assert get_in(manifest, ["spec", "template", "spec", "securityContext"]) == %{
               "fsGroup" => 2000
             }
    end

    test "a volume-less pod carries no securityContext" do
      # Nothing to grant write on — 0 GB entries (Umami's stateless
      # shape) keep the bare pod spec.
      manifest = Deployment.build_manifest("ns", "umami", base_spec())
      pod_spec = get_in(manifest, ["spec", "template", "spec"])

      refute Map.has_key?(pod_spec, "securityContext")
    end

    test "env_from_secret rides a secretRef (user env stays out of the pod spec)" do
      manifest =
        Deployment.build_manifest("ns", "app", Map.put(base_spec(), :env_from_secret, "app-env"))

      assert container(manifest)["envFrom"] == [
               %{"secretRef" => %{"name" => "app-env"}}
             ]
    end

    test "no envFrom without a secret" do
      manifest = Deployment.build_manifest("ns", "app", base_spec())
      app_container = container(manifest)

      refute Map.has_key?(app_container, "envFrom")
    end
  end

  describe "build_manifest/3 — sidecar (#190, ADR-0035)" do
    defp file_access_spec do
      base_spec()
      |> Map.put(:storage_mount, "/data")
      |> Map.put(:pvc_name, "app-data")
      |> Map.put(:sidecar, %{
        image: "rclone/rclone:1.75.2",
        port: 8080,
        args: ["serve", "webdav", "/data", "--addr", "0.0.0.0:8080", "--baseurl", "/dav"],
        env_from_secret: "file-access",
        storage_mount: "/data",
        cpu: 0.05,
        memory: 64
      })
    end

    test "the sidecar lands as a second container sharing the storage volume" do
      manifest = Deployment.build_manifest("ns", "app", file_access_spec())
      pod_spec = get_in(manifest, ["spec", "template", "spec"])
      [app, sidecar] = pod_spec["containers"]

      # the app container is untouched by the sidecar's presence
      assert app["name"] == "app"
      assert app["volumeMounts"] == [%{"name" => "storage", "mountPath" => "/data"}]

      assert sidecar == %{
               "name" => "file-access",
               "image" => "rclone/rclone:1.75.2",
               "ports" => [%{"containerPort" => 8080}],
               "args" => [
                 "serve",
                 "webdav",
                 "/data",
                 "--addr",
                 "0.0.0.0:8080",
                 "--baseurl",
                 "/dav"
               ],
               "envFrom" => [%{"secretRef" => %{"name" => "file-access"}}],
               "resources" => %{
                 "requests" => %{"cpu" => "0.05", "memory" => "64Mi"},
                 "limits" => %{"cpu" => "0.1", "memory" => "128Mi"}
               },
               # same volume, not a second PVC
               "volumeMounts" => [%{"name" => "storage", "mountPath" => "/data"}]
             }

      assert length(pod_spec["volumes"]) == 1
    end

    test "no sidecar container without :sidecar" do
      manifest = Deployment.build_manifest("ns", "app", base_spec())

      assert length(get_in(manifest, ["spec", "template", "spec", "containers"])) == 1
    end

    # #190's quota fix companion: the deployer passes the sidecar's
    # requests as Decimal (exact quota math) — the manifest must build
    # without Kernel arithmetic and stringify exactly.
    test "Decimal sidecar cpu builds exactly" do
      spec = put_in(file_access_spec(), [:sidecar, :cpu], Decimal.new("0.05"))

      manifest = Deployment.build_manifest("ns", "app", spec)
      sidecar = get_in(manifest, ["spec", "template", "spec", "containers", Access.at(1)])

      assert sidecar["resources"]["requests"]["cpu"] == "0.05"
      assert sidecar["resources"]["limits"]["cpu"] == "0.1"
    end
  end

  describe "build_manifest/3 — backing services (#612, ADR-0045)" do
    # The Docmost-class shape: both engines, storage mounted, the
    # requests already carved by the deployer's seam (the carve itself
    # is InstanceK8s' test).
    defp backing_spec do
      base_spec()
      |> Map.put(:storage_mount, "/data")
      |> Map.put(:pvc_name, "app-data")
      |> Map.put(:cpu, Decimal.new("0.85"))
      |> Map.put(:memory, 704)
      |> Map.put(:backing_services, [
        %{
          kind: :postgres,
          image: "postgres:18.6-alpine3.24",
          port: 5432,
          env_from_secret: "backing-services",
          cpu: Decimal.new("0.10"),
          memory_mb: 256
        },
        %{
          kind: :redis,
          image: "redis:8.10.3-alpine3.23",
          port: 6379,
          env_from_secret: "backing-services",
          cpu: Decimal.new("0.05"),
          memory_mb: 64
        }
      ])
    end

    defp init_containers(manifest),
      do: get_in(manifest, ["spec", "template", "spec", "initContainers"])

    test "native sidecars land as init containers, in declaration order, before the app" do
      manifest = Deployment.build_manifest("ns", "app", backing_spec())

      [pg, redis] = init_containers(manifest)
      assert pg["name"] == "postgres"
      assert redis["name"] == "redis"

      # Both gate the pod as native sidecars — the app container (the
      # only regular container here) starts after both pass probes.
      assert pg["restartPolicy"] == "Always"
      assert redis["restartPolicy"] == "Always"

      assert [%{"name" => "app"}] =
               get_in(manifest, ["spec", "template", "spec", "containers"])
    end

    test "postgres: loopback listener, PGDATA subdir, socket-immune probe, subPath mount" do
      manifest = Deployment.build_manifest("ns", "app", backing_spec())
      [pg, _redis] = init_containers(manifest)

      # The listener binds loopback — nothing answers off-pod even
      # with no policy. Args ride the image's entrypoint (initdb path
      # intact); no secret in argv.
      assert pg["args"] == ["postgres", "-c", "listen_addresses=127.0.0.1"]

      assert pg["env"] == [
               # Below the mount: the official image's lost+found quirk
               # on volume roots.
               %{"name" => "PGDATA", "value" => "/var/lib/postgresql/data/pgdata"}
             ]

      # -h 127.0.0.1 is load-bearing: a bare pg_isready would pass
      # against the socket-only initdb temp server.
      assert pg["startupProbe"] == %{
               "exec" => %{"command" => ["pg_isready", "-h", "127.0.0.1"]},
               "periodSeconds" => 5,
               "failureThreshold" => 36
             }

      assert pg["volumeMounts"] == [
               %{
                 "name" => "storage",
                 "mountPath" => "/var/lib/postgresql/data",
                 "subPath" => "backing/postgres"
               }
             ]

      assert pg["envFrom"] == [%{"secretRef" => %{"name" => "backing-services"}}]
      assert pg["ports"] == [%{"containerPort" => 5432}]
      assert pg["image"] == "postgres:18.6-alpine3.24"
    end

    test "redis: requirepass from env (never argv), loopback bind, auth'd ping probe" do
      manifest = Deployment.build_manifest("ns", "app", backing_spec())
      [_pg, redis] = init_containers(manifest)

      # The password expands at runtime from envFrom — the pod spec
      # carries only the variable's name.
      assert redis["command"] == [
               "sh",
               "-c",
               ~s|exec redis-server --requirepass "$REDIS_PASSWORD" | <>
                 "--bind 127.0.0.1 --protected-mode yes"
             ]

      # redis-cli authenticates via REDISCLI_AUTH from the Secret —
      # PONG means auth AND liveness.
      assert redis["startupProbe"] == %{
               "exec" => %{"command" => ["redis-cli", "ping"]},
               "periodSeconds" => 5,
               "failureThreshold" => 12
             }

      assert redis["volumeMounts"] == [
               %{"name" => "storage", "mountPath" => "/data", "subPath" => "backing/redis"}
             ]

      assert redis["envFrom"] == [%{"secretRef" => %{"name" => "backing-services"}}]
      assert redis["ports"] == [%{"containerPort" => 6379}]
    end

    test "requests at the registry shares, limits at the house 2x" do
      manifest = Deployment.build_manifest("ns", "app", backing_spec())
      [pg, redis] = init_containers(manifest)

      assert pg["resources"] == %{
               "requests" => %{"cpu" => "0.1", "memory" => "256Mi"},
               "limits" => %{"cpu" => "0.2", "memory" => "512Mi"}
             }

      assert redis["resources"] == %{
               "requests" => %{"cpu" => "0.05", "memory" => "64Mi"},
               "limits" => %{"cpu" => "0.1", "memory" => "128Mi"}
             }

      # Requests arithmetic = allocation exactly (D1): the app's
      # already-carved requests plus both shares rebuild the envelope
      # the quota sells — 0.85 + 0.10 + 0.05 = 1.0 CPU, 704 + 256 +
      # 64 = 1024 MB.
      app = get_in(manifest, ["spec", "template", "spec", "containers", Access.at(0)])

      cpu =
        [app | init_containers(manifest)]
        |> Enum.map(&Decimal.new(&1["resources"]["requests"]["cpu"]))
        |> Enum.reduce(&Decimal.add/2)

      assert Decimal.eq?(cpu, Decimal.new("1"))

      memory =
        [app | init_containers(manifest)]
        |> Enum.map(fn container ->
          container["resources"]["requests"]["memory"]
          |> String.replace("Mi", "")
          |> String.to_integer()
        end)
        |> Enum.sum()

      assert memory == 1024
    end

    test "no initContainers section without :backing_services" do
      manifest = Deployment.build_manifest("ns", "app", base_spec())

      pod_spec = get_in(manifest, ["spec", "template", "spec"])
      refute Map.has_key?(pod_spec, "initContainers")
    end

    test "one storage volume however many containers mount it" do
      manifest = Deployment.build_manifest("ns", "app", backing_spec())

      volumes = get_in(manifest, ["spec", "template", "spec", "volumes"])

      assert volumes == [
               %{"name" => "storage", "persistentVolumeClaim" => %{"claimName" => "app-data"}}
             ]
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

    test "ensure_env_from adds the Secret to the app container only" do
      deployment =
        put_in(
          fetched_deployment(),
          ["spec", "template", "spec", "containers"],
          [
            %{"name" => "app", "image" => "app:1"},
            %{
              "name" => "file-access",
              "image" => "rclone",
              "envFrom" => [%{"secretRef" => %{"name" => "file-access"}}]
            }
          ]
        )

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: deployment}} end)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        [app, sidecar] = get_in(manifest, ["spec", "template", "spec", "containers"])

        assert app["envFrom"] == [%{"secretRef" => %{"name" => "app-env"}}]

        assert sidecar["envFrom"] == [
                 %{"secretRef" => %{"name" => "file-access"}}
               ]

        annotations = get_in(manifest, ["spec", "template", "metadata", "annotations"])
        assert Map.has_key?(annotations, "fluxvale.io/restartedAt")

        {:ok, %{status: 200, body: manifest}}
      end)

      assert {:ok, _body} =
               Deployment.restart(%{}, "fluxvale-app-1", "forgejo", ensure_env_from: "app-env")
    end

    test "ensure_env_from is idempotent when the app already consumes it" do
      deployment =
        put_in(
          fetched_deployment(),
          ["spec", "template", "spec", "containers"],
          [
            %{
              "name" => "app",
              "image" => "app:1",
              "envFrom" => [
                %{"secretRef" => %{"name" => "other"}},
                %{"secretRef" => %{"name" => "app-env"}}
              ]
            }
          ]
        )

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 200, body: deployment}} end)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        [app] = get_in(manifest, ["spec", "template", "spec", "containers"])

        assert app["envFrom"] == [
                 %{"secretRef" => %{"name" => "other"}},
                 %{"secretRef" => %{"name" => "app-env"}}
               ]

        {:ok, %{status: 200, body: manifest}}
      end)

      assert {:ok, _body} =
               Deployment.restart(%{}, "fluxvale-app-1", "forgejo", ensure_env_from: "app-env")
    end

    test "ensure_env_from tolerates a deployment without containers" do
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: fetched_deployment()}}
      end)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert get_in(manifest, ["spec", "template", "spec", "containers"]) == nil
        {:ok, %{status: 200, body: manifest}}
      end)

      assert {:ok, _body} =
               Deployment.restart(%{}, "fluxvale-app-1", "forgejo", ensure_env_from: "app-env")
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

  describe "apply_manifest/2" do
    test "server-side-applies a caller-built manifest verbatim" do
      manifest = Deployment.build_manifest("ns", "gateway", base_spec())
      # The success path logs the object it applied (the namespace/name
      # interpolation is load-bearing for operators reading logs).

      expect(Kubereq, :apply, fn _req, ^manifest, "fluxvale" ->
        {:ok, %{status: 201, body: %{"kind" => "Deployment"}}}
      end)

      assert {:ok, %{"kind" => "Deployment"}} = Deployment.apply_manifest(%{}, manifest)
    end

    test "the success path logs the applied object" do
      manifest = Deployment.build_manifest("fluxvale-access", "gateway", base_spec())

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 201, body: %{}}}
      end)

      # The suite runs at :warning (config/test.exs), so the info line
      # needs the level opened for this test and restored after.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Deployment.apply_manifest(%{}, manifest)
        end)

      assert log =~ "fluxvale-access/gateway"
    end

    test "an update (200) is success too — SSA is idempotent" do
      manifest = Deployment.build_manifest("ns", "gateway", base_spec())

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 200, body: %{}}}
      end)

      assert {:ok, %{}} = Deployment.apply_manifest(%{}, manifest)
    end

    test "a non-2xx apply is a K8s error" do
      manifest = Deployment.build_manifest("ns", "gateway", base_spec())

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 422, body: %{"message" => "invalid"}}}
      end)

      assert {:error, %FluxVale.Clients.K8s.Error{}} = Deployment.apply_manifest(%{}, manifest)
    end

    test "a transport failure is a K8s error" do
      manifest = Deployment.build_manifest("ns", "gateway", base_spec())

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:error, %{reason: :econnrefused}}
      end)

      assert {:error, %FluxVale.Clients.K8s.Error{}} = Deployment.apply_manifest(%{}, manifest)
    end
  end
end
