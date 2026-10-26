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

  require Ash.Query

  # The gateway's Kubernetes objects, all in the access namespace and
  # all keyed by the gateway's id — one org's gateway must never address
  # (or overwrite) another's. `credential_secret_ref` on the row names
  # the Secret this derives.
  @serve_file "serve.json"

  # Per-gateway object names, never derived from an org or app name
  # (§1's opacity rule).
  #
  # The suffix comes from the RANDOM TAIL of the id: a uuid v7's leading
  # hex is a millisecond timestamp, identical for every gateway created in
  # the same ~65s window, so using it would hand two orgs the same object
  # names — the exact multi-tenancy break this naming exists to prevent.
  # The last 12 hex are the random part.
  defp object_name(prefix, gateway), do: "#{prefix}-#{short_id(gateway)}"

  defp short_id(%AccessGateway{id: id}) do
    id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(-10, 10)
  end

  defp deployment_name(gateway), do: object_name("gateway", gateway)
  defp state_claim_name(gateway), do: object_name("state", gateway)
  defp credential_secret_name(gateway), do: object_name("credential", gateway)
  defp serve_secret_name(gateway), do: object_name("serve-config", gateway)

  defp image, do: Application.fetch_env!(:flux_vale, :access_gateway)[:image]

  # ------------------------------------------------------------------
  # provision_gateway/2
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def provision_gateway(%AccessGateway{} = gateway, auth_key) do
    with {:ok, kubeconfig} <- kubeconfig() do
      namespace = access_namespace()

      result =
        with :ok <- write_credential(kubeconfig, namespace, gateway, auth_key),
             {:ok, _serve} <- write_serve_config(kubeconfig, namespace, gateway),
             {:ok, _pvc} <- ensure_state(kubeconfig, namespace, gateway),
             {:ok, _deploy} <-
               Deployment.apply_manifest(kubeconfig, deployment_manifest(gateway, namespace)) do
          {:ok, :provisioned}
        end

      case result do
        {:ok, :provisioned} ->
          # The row records the Secret's name (never the key) — the
          # moduledoc's contract, and what a reader needs to locate the
          # credential without knowing this module's naming rule.
          {:ok, %{credential_secret_ref: credential_secret_name(gateway)}}

        {:error, _reason} = error ->
          # Cleanup is the CREATE path's business (see
          # `provision_gateway/2`'s doc): the drift-repair retry reads its
          # key FROM this Secret, so deleting it here would turn a
          # transient cluster error into an unrepairable gateway.
          error
      end
    end
  end

  # ------------------------------------------------------------------
  # attach_instance/2
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def attach_instance(%AccessGateway{} = gateway, %Instance{} = instance) do
    with :ok <- require_private(instance),
         {:ok, kubeconfig} <- kubeconfig(),
         # Idempotent by instance identity: a retry (or a double-click)
         # converges on the existing pairing instead of allocating a
         # second port and unwinding the working one in cleanup.
         :none <- existing_route(gateway, instance),
         {:ok, taken} <- taken_ports(gateway),
         {:ok, port} <- Ports.allocate(taken),
         {:ok, route} <- create_route(gateway, instance, port),
         :ok <- apply_routes(kubeconfig, gateway),
         :ok <- admit_gateway(kubeconfig, gateway, instance) do
      {:ok, route}
    else
      {:ok, %AccessRoute{} = existing} ->
        {:ok, existing}

      # A route row that landed but whose cluster work failed is drift
      # the caller's retry re-converges (the attach is idempotent by
      # instance identity); surfacing the error is what keeps the panel
      # honest.
      {:error, _reason} = error ->
        cleanup_failed_attach(gateway, instance, error)
    end
  end

  # ------------------------------------------------------------------
  # detach_instance/2
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def detach_instance(%AccessGateway{} = gateway, %Instance{} = instance) do
    with {:ok, kubeconfig} <- kubeconfig() do
      # Policy first, then the row, then the serve config. The order
      # matters on failure: the policy write is the reachability gate and
      # its error must surface while the route row still exists to retry
      # against (deleting the row first would strand an instance admitted
      # to the access namespace forever — the row is the only record of
      # the pairing).
      with :ok <- disadmit_gateway(kubeconfig, instance),
           :ok <- delete_route(instance) do
        apply_routes(kubeconfig, gateway)
      end
    end
  end

  # The pairing for this instance, if one already exists (the attach
  # idempotence check). Scoped to the gateway: a route on another org's
  # gateway is not this gateway's to adopt.
  defp existing_route(gateway, instance) do
    # System seam: the provider runs actorless (a retry has no caller), so
    # the policy-gated read must be bypassed here — the caller's own
    # authorization is the operation's job (AttachInstance).
    case AccessRoute.get_by_instance(instance.id, authorize?: false) do
      {:ok, %AccessRoute{gateway_id: gateway_id} = route} when gateway_id == gateway.id ->
        {:ok, route}

      _none_or_other ->
        :none
    end
  end

  # ------------------------------------------------------------------
  # gateway_status/1
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def gateway_status(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      observe(kubeconfig, gateway)
    end
  end

  # ------------------------------------------------------------------
  # wake_intercept/2
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
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

  @impl FluxVale.Infrastructure.AccessProvider
  def update_credential(%AccessGateway{state: state} = gateway, auth_key)
      when state in [:suspended, :destroying] do
    # Parked (or being torn down): write the key and stop. A restart is a
    # get→apply that asserts the fetched replica count, so it would
    # resurrect a pod the ladder scaled to 0 — and the observer refuses to
    # override a suspension, so that pod would serve for free. The new key
    # lands on the next resume, which scales the pod up itself.
    with {:ok, kubeconfig} <- kubeconfig() do
      write_credential(kubeconfig, access_namespace(), gateway, auth_key)
    end
  end

  def update_credential(%AccessGateway{} = gateway, auth_key) do
    with {:ok, kubeconfig} <- kubeconfig(),
         :ok <- write_credential(kubeconfig, access_namespace(), gateway, auth_key) do
      # Restart, not recreate: the pod rejoins under the new key with the
      # persisted state, and the Secret update alone would not re-read.
      case Deployment.restart(kubeconfig, access_namespace(), deployment_name(gateway)) do
        {:ok, _deployment} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  @impl FluxVale.Infrastructure.AccessProvider
  def read_credential(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      case Secret.get_data(kubeconfig, access_namespace(), credential_secret_name(gateway)) do
        {:ok, %{"TS_AUTHKEY" => key}} when is_binary(key) and key != "" -> {:ok, key}
        {:ok, _malformed} -> {:error, :credential_malformed}
        {:error, _reason} = error -> error
      end
    end
  end

  # ------------------------------------------------------------------
  # scale_gateway/2
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def scale_gateway(%AccessGateway{} = gateway, replicas) when replicas in [0, 1] do
    with {:ok, kubeconfig} <- kubeconfig() do
      case Deployment.scale(kubeconfig, access_namespace(), deployment_name(gateway), replicas) do
        {:ok, _deployment} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  # ------------------------------------------------------------------
  # teardown_gateway/1
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def teardown_gateway(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      namespace = access_namespace()

      # Detach every instance first: each detach re-admits only
      # same-namespace and rewrites the serve config, so an instance can
      # never be left pointing at a gateway that no longer exists.
      attached = AccessGateway.attached_instances(gateway)
      Enum.each(attached, &detach_instance(gateway, &1))

      with :ok <- safe_delete_deployment(kubeconfig, namespace, gateway),
           :ok <- safe_delete_secret(kubeconfig, namespace, serve_secret_name(gateway)),
           :ok <- safe_delete_secret(kubeconfig, namespace, credential_secret_name(gateway)) do
        safe_delete_pvc(kubeconfig, namespace, state_claim_name(gateway))
      end
    end
  end

  # ==================================================================
  # Credential
  # ==================================================================

  # `TS_AUTHKEY` only. The row stores the ref; nothing reads the value
  # back out (no reveal path exists, deliberately — ADR-0039 §4).
  defp write_credential(kubeconfig, namespace, gateway, auth_key) do
    name = credential_secret_name(gateway)

    case Secret.create(kubeconfig, namespace, name, %{"TS_AUTHKEY" => auth_key}) do
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
      |> Enum.flat_map(fn route ->
        case Ash.get(Instance, route.instance_id, authorize?: false) do
          {:ok, instance} ->
            [{route.route_key, ServeConfig.target_for(gateway.id, instance)}]

          # Vanished between the read and this build. The FK cascades the
          # route with its instance, so this is only reachable if a read
          # races a teardown inside one call — defensive, and skipping is
          # the right answer: the next detach converges the leftover.
          # coveralls-ignore-next-line race only: the FK cascades the route first
          {:error, _not_found} ->
            []
        end
      end)

    config = ServeConfig.build(gateway.hostname, entries)

    case Secret.create(kubeconfig, namespace, serve_secret_name(gateway), %{
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
    # Both cleanups are best-effort: the original error is what the
    # caller surfaces and retries on. `delete_route/1` is scoped to this
    # gateway AND checks the row is still the one we created, so a
    # concurrent attach that won the race keeps its pairing.
    delete_route(gateway, instance)

    # coveralls-ignore-start - unreachable here: the attach that reached
    # this arm already resolved a kubeconfig moments ago
    case kubeconfig() do
      {:ok, kubeconfig} -> apply_routes(kubeconfig, gateway)
      _no_cluster -> :ok
    end

    # coveralls-ignore-stop

    error
  end

  # Detach's delete: the instance's pairing (the row is unique per
  # instance, so no gateway scope is needed there).
  defp delete_route(instance) do
    case route_for(instance) do
      nil -> :ok
      route -> AccessRoute.destroy(route, authorize?: false)
    end
  end

  # Cleanup's delete: only the pairing THIS attach created. A concurrent
  # attach that won the unique index must keep its route, so a bare
  # delete-by-instance would tear down the winner's work.
  defp delete_route(gateway, instance) do
    case route_for(instance) do
      %AccessRoute{gateway_id: gateway_id} = route when gateway_id == gateway.id ->
        AccessRoute.destroy(route, authorize?: false)

      _none_or_other_gateway ->
        :ok
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
    # Defensive: only a malformed/duplicate row written out of band
    # reaches this — the identity makes it impossible through the app.
    # coveralls-ignore-next-line
    Ash.Error.Invalid -> nil
  end

  # ==================================================================
  # NetworkPolicy
  # ==================================================================

  # Attaching admits the ACCESS NAMESPACE, never the edge (ADR-0038 §5's
  # constraint): the private policy's external list gains exactly one
  # namespace. The edge entry stays absent in every private state.
  defp admit_gateway(_kubeconfig, _gateway, %{namespace: nil}), do: :ok

  defp admit_gateway(kubeconfig, gateway, instance) do
    # The pod selector is load-bearing: without it the policy admits
    # EVERY pod in the access namespace, so org B's gateway would reach
    # org A's app through the shared namespace (the same multi-tenancy
    # break the per-gateway object names close).
    apply_policy(kubeconfig, instance, [access_namespace()],
      match_labels: selector_labels(gateway)
    )
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

  defp apply_policy(kubeconfig, instance, external_namespaces, opts \\ []) do
    spec = build_spec(external_namespaces, opts[:match_labels])

    case NetworkPolicy.create(kubeconfig, instance.namespace, policy_name(), spec) do
      {:ok, _policy} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The detach path passes no labels (the private floor, whole-namespace
  # empty); the attach path narrows the one namespace to this gateway.
  defp build_spec(namespaces, nil), do: %{ingress_from_namespaces: namespaces}

  defp build_spec(namespaces, labels) do
    %{ingress_from_sources: Enum.map(namespaces, &%{namespace: &1, match_labels: labels})}
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
    case Deployment.status(kubeconfig, access_namespace(), deployment_name(gateway)) do
      # `ready?/1`, not `ready >= replicas`: after a pod-template change
      # (the re-paste restart, a re-provision) readyReplicas still counts
      # the OLD pod until the controller rolls the new generation, so the
      # bare comparison would report "Connected" and keep billing for a
      # gateway that is mid-restart.
      {:ok, status} when is_map(status) ->
        classify(status, gateway)

      # No Deployment. A row still in :provisioning has simply not had its
      # apply land yet; a row past that (:active/:needs_attention) has
      # LOST its Deployment, which is drift — reporting :provisioning
      # there would leave the panel saying "Setting up access" and (for
      # :active) keep metering a pod that does not exist.
      {:error, %Error{reason: :not_found}} ->
        if gateway.state == :provisioning do
          {:ok, %{state: :provisioning, message: "Setting up access"}}
        else
          {:ok, %{state: :needs_attention, message: "Not connected — the gateway pod is missing"}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp classify(%{replicas: 0}, gateway) do
    # Scaled to zero — the ladder's suspension. The row's own state is
    # the authority there; report it unchanged.
    {:ok, %{state: gateway.state, message: "Access is paused"}}
  end

  defp classify(status, _gateway) do
    if Deployment.ready?(status) do
      {:ok, %{state: :active, message: "Connected to your tailnet"}}
    else
      {:ok,
       %{state: :needs_attention, message: "Not connected — check the access key and reconnect"}}
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
        "name" => deployment_name(gateway),
        "namespace" => namespace,
        "labels" => labels(gateway)
      },
      "spec" => %{
        "replicas" => 1,
        # Recreate, not RollingUpdate: the state PVC is ReadWriteOnce and
        # holds the tailscaled node identity, so the old pod must be gone
        # before the new one mounts it (a rolling update can double-mount
        # on one node, or Multi-Attach-timeout across nodes, during the
        # re-paste restart).
        "strategy" => %{"type" => "Recreate"},
        # Per-gateway selector: a shared one would let each gateway's
        # Deployment adopt every other gateway's pods (they would fight
        # over the same ReplicaSets), and the NetworkPolicy's pod
        # admission below keys on the same label.
        "selector" => %{"matchLabels" => selector_labels(gateway)},
        "template" => %{
          "metadata" => %{"labels" => selector_labels(gateway)},
          "spec" => %{
            # No securityContext, no capabilities, no hostNetwork — the
            # zero-privilege posture (§1) is an ABSENCE here, deliberately.
            "containers" => [container(gateway, namespace)],
            "volumes" => volumes(gateway)
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
        %{"name" => "POD_IP", "valueFrom" => %{"fieldRef" => %{"fieldPath" => "status.podIP"}}},
        %{
          "name" => "TS_AUTHKEY",
          "valueFrom" => %{
            "secretKeyRef" => %{
              "name" => credential_secret_name(gateway),
              "key" => "TS_AUTHKEY"
            }
          }
        }
      ],
      "ports" => [%{"containerPort" => 41_641, "protocol" => "UDP"}],
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

  defp volumes(gateway) do
    [
      %{
        "name" => "state",
        "persistentVolumeClaim" => %{"claimName" => state_claim_name(gateway)}
      },
      %{"name" => "serve", "secret" => %{"secretName" => serve_secret_name(gateway)}}
    ]
  end

  # tailscaled's persisted identity (node key + prefs) — kilobytes, but
  # it MUST survive a restart or the node rejoins as a stranger (§4).
  defp ensure_state(kubeconfig, namespace, gateway) do
    PersistentVolumeClaim.create(kubeconfig, namespace, state_claim_name(gateway), %{
      size: "64Mi"
    })
  end

  defp labels(gateway) do
    selector = selector_labels(gateway)
    Map.put(selector, "app.kubernetes.io/managed-by", "fluxvale")
  end

  # The pod labels a gateway's Deployment selects. The same pair is what
  # the instance NetworkPolicy matches on, so the source lives in
  # InstanceK8s (the policy's owner) rather than being duplicated here —
  # a divergence between the two is a silent reachability change.
  defp selector_labels(gateway) do
    FluxVale.Infrastructure.Operations.InstanceK8s.gateway_pod_labels(gateway.id)
  end

  # ==================================================================
  # Teardown helpers
  # ==================================================================

  defp safe_delete_deployment(kubeconfig, namespace, gateway),
    do:
      safe_delete(fn ->
        Deployment.delete(kubeconfig, namespace, deployment_name(gateway))
      end)

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
      {:ok, [cluster]} ->
        K8s.kubeconfig(cluster.kubeconfig_ref)

      {:ok, []} ->
        {:error, :no_cluster}

      # coveralls-ignore-start - staging a second cluster breaks the
      # suite-wide exactly-one-cluster invariant every other test relies
      # on; the arm is the ADR-0006 refusal, pinned by construction
      {:ok, _multiple} ->
        {:error, :multiple_clusters}

      # coveralls-ignore-stop

      # coveralls-ignore-start - defensive: cluster read DB failure
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp access_namespace do
    Application.fetch_env!(:flux_vale, :access_gateway)[:namespace] || "fluxvale-access"
  end
end
