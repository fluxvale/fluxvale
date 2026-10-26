defmodule FluxVale.Infrastructure.AccessProviders.Tailscale do
  @moduledoc """
  The Tailscale implementation of `AccessProvider` (ADR-0039): a
  per-org userspace `tailscaled` gateway pod that serves the org's
  private instances over the owner's own tailnet.

  **Zero pod privileges** (§1): the official image, `TS_USERSPACE`
  (its default), no `securityContext`, no `/dev/net/tun`, no
  `NET_ADMIN` — Tailscale's own posture for containers, and the reason
  this design needs nothing from Talos. The spike proved the boundary
  at kernel level: kernel-mode `--tun=<name>` fails `TUNSETIFF` with
  EPERM as an unprivileged process; userspace serves with none.

  **The routing table is a Secret the platform writes** (§3). Serve has
  no hostname dimension, so the gateway serves one name and one
  hostname-multiplexed set of **ports**; `ServeConfig` builds that JSON
  from the gateway's `access_routes`. `containerboot` watches the
  mounted file and re-applies on change, so every routing change is an
  ordinary platform write.

  **The auth key never reaches Postgres** (§4): it is written to the
  gateway's Secret; the row holds only the Secret's name. Persisted
  state lives on a small PVC, so a restart rejoins as the same node
  (tagged, non-ephemeral — the key is join-time, not runtime).

  All cluster access resolves through the gateway's own cluster (the
  platform's single cluster today — `Cluster` is the placement seam).
  """

  @behaviour FluxVale.Infrastructure.AccessProvider

  require Ash.Query

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.NetworkPolicy
  alias FluxVale.Clients.K8s.Resources.PersistentVolumeClaim
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.Ports
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfig
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance

  # The gateway's Kubernetes objects, all in the access namespace.
  @deployment "gateway"
  @state_claim "state"
  @credential_secret "credential"
  @serve_secret "serve-config"
  @serve_file "serve.json"

  defp image, do: Application.fetch_env!(:flux_vale, :access_gateway)[:image]

  # ------------------------------------------------------------------
  # provision_gateway/2
  # ------------------------------------------------------------------

  @impl true
  def provision_gateway(%AccessGateway{} = gateway, auth_key) do
    with {:ok, kubeconfig} <- kubeconfig(),
         namespace = access_namespace(),
         :ok <- write_credential(kubeconfig, namespace, auth_key),
         {:ok, _serve} <- write_serve_config(kubeconfig, namespace, gateway),
         {:ok, _pvc} <- ensure_state(kubeconfig, namespace),
         {:ok, _deploy} <-
           Deployment.apply_manifest(kubeconfig, deployment_manifest(gateway, namespace)) do
      {:ok, :provisioned}
    end
  end

  # ------------------------------------------------------------------
  # attach_instance/2
  # ------------------------------------------------------------------

  @impl true
  def attach_instance(%AccessGateway{} = gateway, %Instance{} = instance) do
    with :ok <- require_private(instance),
         {:ok, kubeconfig} <- kubeconfig(),
         {:ok, taken} <- taken_ports(gateway),
         {:ok, port} <- Ports.allocate(taken),
         {:ok, route} <- create_route(gateway, instance, port),
         :ok <- apply_routes(kubeconfig, gateway),
         :ok <- admit_gateway(kubeconfig, instance) do
      {:ok, route}
    else
      # A route row that landed but whose cluster work failed is drift
      # the caller's retry re-converges (the attach is idempotent by
      # instance identity); surfacing the error is what keeps the panel
      # honest.
      {:error, _reason} = error -> cleanup_failed_attach(gateway, instance, error)
    end
  end

  # ------------------------------------------------------------------
  # detach_instance/2
  # ------------------------------------------------------------------

  @impl true
  def detach_instance(%AccessGateway{} = gateway, %Instance{} = instance) do
    with {:ok, kubeconfig} <- kubeconfig() do
      _removed = delete_route(instance)
      # Policy first-then-serve order does not matter here: both are
      # idempotent removals and the policy's removal alone already
      # closes reachability (the pod cannot reach the namespace).
      _policy = disadmit_gateway(kubeconfig, instance)
      apply_routes(kubeconfig, gateway)
    end
  end

  # ------------------------------------------------------------------
  # gateway_status/1
  # ------------------------------------------------------------------

  @impl true
  def gateway_status(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      observe(kubeconfig, gateway)
    end
  end

  # ------------------------------------------------------------------
  # wake_intercept/2
  # ------------------------------------------------------------------

  @impl true
  def wake_intercept(%AccessGateway{} = gateway, %Instance{}) do
    with {:ok, kubeconfig} <- kubeconfig() do
      # The instance is :running now, so the route's target must become
      # the app itself. Rewriting the whole serve config is the simple,
      # convergent move: every route is regenerated from its row's
      # current instance status, so a concurrent detach cannot be
      # resurrected by a stale partial write.
      write_serve_config(kubeconfig, access_namespace(), gateway)
    end
  end

  # ------------------------------------------------------------------
  # update_credential/2
  # ------------------------------------------------------------------

  @impl true
  def update_credential(%AccessGateway{}, auth_key) do
    with {:ok, kubeconfig} <- kubeconfig(),
         :ok <- write_credential(kubeconfig, access_namespace(), auth_key) do
      # Restart, not recreate: the pod rejoins under the new key with the
      # persisted state, and the Secret update alone would not re-read.
      Deployment.restart(kubeconfig, access_namespace(), @deployment)
    end
  end

  @impl true
  def read_credential(%AccessGateway{}) do
    with {:ok, kubeconfig} <- kubeconfig() do
      case Secret.get_data(kubeconfig, access_namespace(), @credential_secret) do
        {:ok, %{"TS_AUTHKEY" => key}} when is_binary(key) and key != "" -> {:ok, key}
        {:ok, _malformed} -> {:error, :credential_malformed}
        {:error, _reason} = error -> error
      end
    end
  end

  # ------------------------------------------------------------------
  # scale_gateway/2
  # ------------------------------------------------------------------

  @impl true
  def scale_gateway(%AccessGateway{}, replicas) when replicas in [0, 1] do
    with {:ok, kubeconfig} <- kubeconfig() do
      case Deployment.scale(kubeconfig, access_namespace(), @deployment, replicas) do
        {:ok, _deployment} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  # ------------------------------------------------------------------
  # teardown_gateway/1
  # ------------------------------------------------------------------

  @impl true
  def teardown_gateway(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      namespace = access_namespace()

      # Detach every instance first: each detach re-admits only
      # same-namespace and rewrites the serve config, so an instance can
      # never be left pointing at a gateway that no longer exists.
      _detached =
        Enum.each(AccessGateway.attached_instances(gateway), &detach_instance(gateway, &1))

      with :ok <- safe_delete_deployment(kubeconfig, namespace),
           :ok <- safe_delete_secret(kubeconfig, namespace, @serve_secret),
           :ok <- safe_delete_secret(kubeconfig, namespace, @credential_secret),
           :ok <- safe_delete_pvc(kubeconfig, namespace, @state_claim) do
        :ok
      end
    end
  end

  # ==================================================================
  # Credential
  # ==================================================================

  # `TS_AUTHKEY` only. The row stores the ref; nothing reads the value
  # back out (no reveal path exists, deliberately — ADR-0039 §4).
  defp write_credential(kubeconfig, namespace, auth_key) do
    case Secret.create(kubeconfig, namespace, @credential_secret, %{"TS_AUTHKEY" => auth_key}) do
      {:ok, _secret} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # ==================================================================
  # Serve config
  # ==================================================================

  # Regenerates the config from the routes, then writes it to the Secret
  # `containerboot` watches. A route whose instance has vanished between
  # the read and this build is skipped (its row is the source of truth
  # elsewhere; the next detach converges it).
  defp write_serve_config(kubeconfig, namespace, gateway) do
    entries =
      gateway
      |> routes_for()
      |> Enum.map(fn route ->
        instance = Ash.get!(Instance, route.instance_id, authorize?: false)
        {route.route_key, ServeConfig.target_for(gateway.id, instance)}
      end)

    config = ServeConfig.build(gateway.hostname, entries)

    case Secret.create(kubeconfig, namespace, @serve_secret, %{
           @serve_file => ServeConfig.encode(config)
         }) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} = error -> error
    end
  end

  defp apply_routes(kubeconfig, gateway) do
    case write_serve_config(kubeconfig, access_namespace(), gateway) do
      {:ok, _secret} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ==================================================================
  # Routes
  # ==================================================================

  defp taken_ports(gateway) do
    routes = routes_for(gateway)
    {:ok, Enum.map(routes, & &1.route_key)}
  end

  defp create_route(gateway, instance, port) do
    AccessRoute.create(
      %{gateway_id: gateway.id, instance_id: instance.id, route_key: port},
      authorize?: false
    )
  end

  # The attach failed after the row may have landed: remove it so a
  # retry starts clean. A leftover row would hold a port and — worse —
  # read as the owner's consent for a wake the owner never got service
  # for. The policy and serve config are re-derived from the rows, so
  # removing the row is enough for both; the original error is preserved.
  defp cleanup_failed_attach(gateway, instance, error) do
    _ = delete_route(instance)

    _ =
      case kubeconfig() do
        {:ok, kubeconfig} -> apply_routes(kubeconfig, gateway)
        _no_cluster -> :ok
      end

    error
  end

  defp delete_route(instance) do
    case route_for(instance) do
      nil -> :ok
      route -> AccessRoute.destroy(route, authorize?: false)
    end
  end

  # The provider is a SYSTEM seam: it reads the pairing table with
  # `authorize?: false` (the operations' posture — no actor exists on the
  # create/settle/wake paths), never through a member-policied read.
  defp routes_for(gateway) do
    gateway_id = gateway.id

    AccessRoute
    |> Ash.Query.filter(gateway_id == ^gateway_id)
    |> Ash.read!(authorize?: false)
  end

  defp route_for(instance) do
    instance_id = instance.id

    AccessRoute
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.read_one!(authorize?: false)
  rescue
    Ash.Error.Invalid -> nil
  end

  # ==================================================================
  # NetworkPolicy
  # ==================================================================

  # Attaching admits the ACCESS NAMESPACE, never the edge (ADR-0038 §5's
  # constraint): the private policy's external list gains exactly one
  # namespace. The edge entry stays absent in every private state.
  defp admit_gateway(_kubeconfig, %{namespace: nil}), do: :ok

  defp admit_gateway(kubeconfig, instance) do
    apply_policy(kubeconfig, instance, [access_namespace()])
  end

  # Detach returns the namespace to the private floor (same-namespace
  # only). A public instance is left alone: its policy admits the edge
  # and detaching never narrows that (the two switches are independent —
  # ADR-0039 §3).
  defp disadmit_gateway(_kubeconfig, %{namespace: nil}), do: :ok

  defp disadmit_gateway(kubeconfig, %{exposure: :private} = instance) do
    apply_policy(kubeconfig, instance, [])
  end

  defp disadmit_gateway(_kubeconfig, _instance), do: :ok

  defp apply_policy(kubeconfig, instance, external_namespaces) do
    case NetworkPolicy.create(
           kubeconfig,
           instance.namespace,
           policy_name(),
           %{ingress_from_namespaces: external_namespaces}
         ) do
      {:ok, _policy} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The same object name EdgeRoutes / InstanceK8s / SetExposure use.
  defp policy_name, do: "default-deny-ingress"

  # ==================================================================
  # Status
  # ==================================================================

  # Read-only observation (§2): Deployment readiness IS the pod-level
  # answer, and it is the one signal available without a pod-local proxy
  # or pods/exec. `:active` = the Deployment exists with its desired
  # replica ready; `:provisioning` = not yet created (or scaled);
  # `:needs_attention` = created but not ready (bad key, crashloop).
  defp observe(kubeconfig, gateway) do
    case Deployment.status(kubeconfig, access_namespace(), @deployment) do
      {:ok, %{ready: ready, replicas: desired}} when desired > 0 and ready >= desired ->
        {:ok, %{state: :active, message: "Connected to your tailnet"}}

      {:ok, %{replicas: 0}} ->
        # Scaled to zero — the ladder's suspension. The row's own state
        # is the authority there; report it unchanged.
        {:ok, %{state: gateway.state, message: "Access is paused"}}

      {:ok, _not_ready} ->
        {:ok,
         %{
           state: :needs_attention,
           message: "Not connected — check the access key and reconnect"
         }}

      {:error, %Error{reason: :not_found}} ->
        {:ok, %{state: :provisioning, message: "Setting up access"}}

      {:error, _reason} = error ->
        error
    end
  end

  # ==================================================================
  # Manifests
  # ==================================================================

  defp deployment_manifest(gateway, namespace) do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => @deployment,
        "namespace" => namespace,
        "labels" => labels(gateway)
      },
      "spec" => %{
        "replicas" => 1,
        "selector" => %{"matchLabels" => %{"app.kubernetes.io/name" => "access-gateway"}},
        "template" => %{
          "metadata" => %{"labels" => %{"app.kubernetes.io/name" => "access-gateway"}},
          "spec" => %{
            # No securityContext, no capabilities, no hostNetwork — the
            # zero-privilege posture (§1) is an ABSENCE here, deliberately.
            "containers" => [container(gateway, namespace)],
            "volumes" => volumes()
          }
        }
      }
    }
  end

  defp container(gateway, _namespace) do
    %{
      "name" => "tailscale",
      "image" => image(),
      "env" => [
        %{"name" => "TS_USERSPACE", "value" => "true"},
        %{"name" => "TS_AUTH_ONCE", "value" => "true"},
        %{"name" => "TS_HOSTNAME", "value" => gateway.hostname},
        %{"name" => "TS_STATE_DIR", "value" => "/state"},
        %{"name" => "TS_SERVE_CONFIG", "value" => "/serve/#{@serve_file}"},
        %{"name" => "TS_ENABLE_HEALTH_CHECK", "value" => "true"},
        %{"name" => "TS_KUBE_SECRET", "value" => ""},
        %{"name" => "POD_IP", "value_from" => %{"fieldRef" => %{"fieldPath" => "status.podIP"}}},
        %{
          "name" => "TS_AUTHKEY",
          "value_from" => %{
            "secretKeyRef" => %{"name" => @credential_secret, "key" => "TS_AUTHKEY"}
          }
        }
      ],
      "ports" => [%{"containerPort" => 41641, "protocol" => "UDP"}],
      "volumeMounts" => [
        %{"name" => "state", "mountPath" => "/state"},
        %{"name" => "serve", "mountPath" => "/serve", "readOnly" => true}
      ],
      "resources" => %{
        # The operator's own userspace proxy template asks for exactly
        # this (§1's evidence); limits give a bursty process headroom.
        "requests" => %{"cpu" => "5m", "memory" => "64Mi"},
        "limits" => %{"cpu" => "100m", "memory" => "192Mi"}
      },
      "readinessProbe" => %{
        "httpGet" => %{"path" => "/healthz", "port" => 9002},
        "periodSeconds" => 10,
        "failureThreshold" => 3
      },
      "livenessProbe" => %{
        "httpGet" => %{"path" => "/healthz", "port" => 9002},
        "periodSeconds" => 30,
        "failureThreshold" => 5
      }
    }
  end

  defp volumes do
    [
      %{"name" => "state", "persistentVolumeClaim" => %{"claimName" => @state_claim}},
      %{"name" => "serve", "secret" => %{"secretName" => @serve_secret}}
    ]
  end

  # tailscaled's persisted identity (node key + prefs) — kilobytes, but
  # it MUST survive a restart or the node rejoins as a stranger (§4).
  defp ensure_state(kubeconfig, namespace) do
    PersistentVolumeClaim.create(kubeconfig, namespace, @state_claim, %{size: "64Mi"})
  end

  defp labels(gateway) do
    %{
      "app.kubernetes.io/managed-by" => "fluxvale",
      "app.kubernetes.io/name" => "access-gateway",
      "fluxvale.io/gateway" => gateway.id
    }
  end

  # ==================================================================
  # Teardown helpers
  # ==================================================================

  defp safe_delete_deployment(kubeconfig, namespace),
    do: safe_delete(fn -> Deployment.delete(kubeconfig, namespace, @deployment) end)

  defp safe_delete_secret(kubeconfig, namespace, name),
    do: safe_delete(fn -> Secret.delete(kubeconfig, namespace, name) end)

  defp safe_delete_pvc(kubeconfig, namespace, name),
    do: safe_delete(fn -> PersistentVolumeClaim.delete(kubeconfig, namespace, name) end)

  # 404 is the posture already holding — teardown is idempotent (the
  # TeardownInstance safe_delete stance).
  defp safe_delete(fun) do
    case fun.() do
      :ok -> :ok
      {:error, %Error{reason: :not_found}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # ==================================================================
  # Small shared helpers
  # ==================================================================

  defp require_private(%{exposure: :private}), do: :ok

  defp require_private(%{exposure: _public}) do
    {:error, :not_private}
  end

  # The instance lifecycle's own placement contract (ResolveCluster):
  # exactly one cluster in M3, read as global config. More than one is
  # the multi-cluster work ADR-0006 owns, refused loudly rather than
  # guessing (a gateway on the wrong cluster reaches nothing).
  defp kubeconfig do
    case Ash.read(FluxVale.Infrastructure.Cluster, authorize?: false) do
      {:ok, [cluster]} -> K8s.kubeconfig(cluster.kubeconfig_ref)
      {:ok, []} -> {:error, :no_cluster}
      {:ok, _multiple} -> {:error, :multiple_clusters}
      # coveralls-ignore-start - defensive: cluster read DB failure
      {:error, _reason} = error -> error
      # coveralls-ignore-stop
    end
  end

  defp access_namespace do
    Application.fetch_env!(:flux_vale, :access_gateway)[:namespace] || "fluxvale-access"
  end
end
