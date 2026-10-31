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

  The **API token is the second credential** (ADR-0040 §5): the
  tailnet-claiming writes — subnet-route approval and split-DNS — go
  through it, under the same Secret discipline. API keys expire
  ≤90 days by design, so the drift observer lands a rejection
  (`:unauthorized`) honestly instead of leaving the panel saying
  Connected.

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
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.Ports
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ServeConfig
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Ash.Query
  require Logger

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
  defp api_credential_secret_name(gateway), do: object_name("api-credential", gateway)
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
    # Resolve BEFORE the first write: the resolver raises on missing
    # config, and the cleanup clauses below only run for error tuples —
    # a raise after create_route lands would strand the row, and the
    # idempotent retry would then report {:ok, existing} without the
    # cluster limbs ever landing.
    _namespace = access_namespace()

    with :ok <- require_private(instance),
         {:ok, kubeconfig} <- kubeconfig(),
         # Idempotent by instance identity: a retry (or a double-click)
         # converges on the existing pairing instead of allocating a
         # second port and unwinding the working one in cleanup.
         :none <- existing_route(gateway, instance),
         {:ok, taken} <- taken_ports(gateway),
         {:ok, port} <- Ports.allocate(taken),
         {:ok, route} <- create_route(gateway, instance, port) do
      finish_attach(kubeconfig, gateway, instance, route)
    else
      {:ok, %AccessRoute{} = existing} ->
        {:ok, existing}

      {:error, _reason} = error ->
        cleanup_failed_attach(gateway, instance, error)
    end
  end

  # The cluster limbs, split out so the route this attempt created is in
  # hand when they fail — cleanup must delete THAT row and no other.
  defp finish_attach(kubeconfig, gateway, instance, route) do
    with :ok <- apply_routes(kubeconfig, gateway),
         :ok <- admit_gateway(kubeconfig, gateway, instance) do
      {:ok, route}
    else
      # A route row that landed but whose cluster work failed is drift the
      # caller's retry re-converges (the attach is idempotent by instance
      # identity); surfacing the error is what keeps the panel honest.
      {:error, _reason} = error -> cleanup_failed_attach(gateway, instance, error, route)
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
        apply_after_detach(kubeconfig, gateway, instance)
      end
    end
  end

  # The migration window only: OTHER routes may remain whose rewrite
  # needs a domain the row does not carry (the same reason their attach
  # is refused). THIS pairing's removal is complete — policy withdrawn,
  # row deleted — and the remaining routes' mounted config is the broken
  # literal regardless, so failing the detach would only strand a
  # deletion the owner cannot retry (the row is gone; re-attach is
  # refused too). The next rewrite the gateway CAN write — the owner's
  # re-paste — regenerates from the rows and drops this port.
  defp apply_after_detach(kubeconfig, gateway, instance) do
    case apply_routes(kubeconfig, gateway) do
      :ok ->
        :ok

      {:error, :tailnet_domain_missing} = tolerated ->
        Logger.warning(
          "Access gateway #{gateway.id} serve-config rewrite skipped after detaching " <>
            "instance #{instance.id}: no tailnet domain on the row; remaining routes stay " <>
            "on their stale config until the owner re-pastes (#{inspect(tolerated)})"
        )

        :ok

      {:error, _reason} = error ->
        error
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
  # claim_domain/3 and unclaim_domain/2 (ADR-0040 §3)
  # ------------------------------------------------------------------

  # The org's tailnet must RESOLVE the claimed hostname through
  # FluxVale: two one-time API writes per (tailnet, domain) — approve
  # the gateway's advertised resolver /32 (subnet routes) and add the
  # domain's split-DNS route pointing at the resolver. The token is a
  # NEW trust surface (§5): read from the Secret, used here, never
  # logged.
  @impl FluxVale.Infrastructure.AccessProvider
  def claim_domain(%AccessGateway{} = gateway, domain, resolver_ip) do
    with {:ok, token} <- read_api_credential(gateway),
         {:ok, device} <- tailnet_node(token, gateway),
         :ok <- ensure_subnet_route(token, device.id, resolver_ip),
         :ok <- ensure_split_dns(token, domain, resolver_ip) do
      {:ok, %{device_id: device.id, route: route_cidr(resolver_ip)}}
    end
  end

  # The mirror. The split-DNS route is tailnet-global and SHARED — it is
  # unset only when no OTHER gateway on this tailnet still claims the
  # domain (one route per tailnet+domain serves all of them, §3: claims
  # are per-gateway rows, the route is one). The /32 is per-node
  # plumbing serving ALL of this gateway's claimed domains, so it comes
  # off only when this gateway's LAST claim goes. Idempotent: an
  # unclaimed domain still unsets (a no-op patch) and skips the route.
  @impl FluxVale.Infrastructure.AccessProvider
  def unclaim_domain(%AccessGateway{} = gateway, domain) do
    with {:ok, token} <- read_api_credential(gateway),
         :ok <- maybe_unset_split_dns(token, gateway, domain) do
      maybe_disable_route(token, gateway, domain)
    end
  end

  defp tailnet_node(token, gateway) do
    case ApiClient.devices_lookup(token, gateway.hostname) do
      {:ok, device} ->
        {:ok, device}

      {:error, :not_found} ->
        {:error, :node_not_found}

      {:error, _reason} = error ->
        error
    end
  end

  # Read → union → set: the POST REPLACES the enabled list, so ours is
  # unioned with what is already enabled — and enabled even though the
  # node may not advertise it yet (documented API capability; the node
  # picks the route up when it starts advertising). A re-claim whose
  # route is already enabled makes NO write.
  defp ensure_subnet_route(token, device_id, resolver_ip) do
    ours = route_cidr(resolver_ip)

    case ApiClient.routes_get(token, device_id) do
      {:ok, routes} ->
        if ours in routes.enabled do
          :ok
        else
          ApiClient.routes_set(token, device_id, Enum.uniq([ours | routes.enabled]))
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The PATCH is a native per-domain upsert: a re-claim whose value
  # already matches makes NO write; any other state (absent, stale IP)
  # converges with one patch.
  defp ensure_split_dns(token, domain, resolver_ip) do
    case ApiClient.split_dns_get(token) do
      {:ok, current} ->
        if Map.get(current, domain) == [resolver_ip] do
          :ok
        else
          ApiClient.split_dns_patch(token, %{domain => [resolver_ip]})
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The claims are gateway-scoped rows on a SHARED tailnet (the owner's
  # own two-org case, §10), so "still claimed" is checked over the
  # RECORDED tailnet identifier — the tailnet suffix each gateway's
  # owner typed at claim time, stored IN the claim entry. A live read
  # of `tailnet_domain` would fork: a re-paste that CORRECTS a mistyped
  # suffix would make this gateway stop recognising the other
  # claimants recorded under the old suffix, and a legitimate unset
  # would be skipped. Recorded-to-recorded is stable under any
  # later correction.
  defp maybe_unset_split_dns(token, gateway, domain) do
    if other_claimant?(gateway, domain) do
      :ok
    else
      ApiClient.split_dns_patch(token, %{domain => nil})
    end
  end

  defp other_claimant?(gateway, domain) do
    gateway_id = gateway.id
    mine = recorded_tailnet(gateway, domain)

    AccessGateway
    |> Ash.Query.filter(id != ^gateway_id)
    |> Ash.read!(authorize?: false)
    |> Enum.any?(fn other ->
      claim = Map.get(other.dns_claims || %{}, domain)
      is_map(claim) and Map.get(claim, "tailnet") == mine
    end)
  end

  # What THIS gateway recorded as the tailnet when it claimed the
  # domain (P2-14) — never a fresh read of the row's suffix.
  defp recorded_tailnet(gateway, domain) do
    case Map.get(gateway.dns_claims || %{}, domain) do
      %{"tailnet" => tailnet} -> tailnet
      _no_entry -> nil
    end
  end

  defp maybe_disable_route(token, gateway, domain) do
    remaining = Map.delete(gateway.dns_claims || %{}, domain)

    if map_size(remaining) > 0 do
      :ok
    else
      drop_subnet_route(token, gateway, domain)
    end
  end

  defp drop_subnet_route(token, gateway, domain) do
    ours = claimed_route(gateway, domain)

    case tailnet_node(token, gateway) do
      {:ok, %{id: device_id}} when is_binary(ours) ->
        disable_route(token, device_id, ours)

      # No route of ours identifiable (never claimed here, no resolver
      # configured): nothing to disable.
      {:ok, _device} ->
        :ok

      # The node already left the tailnet: its routes died with it —
      # the DNS unset above was the dangling state.
      {:error, :node_not_found} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  # The /32 this gateway claimed with: the entry's recorded IP (what we
  # actually enabled), falling back to the configured resolver. Nothing
  # identifiable means nothing to remove.
  defp claimed_route(gateway, domain) do
    case Map.get(gateway.dns_claims || %{}, domain) do
      %{"ip" => ip} when is_binary(ip) ->
        route_cidr(ip)

      _never_claimed ->
        resolver_route()
    end
  end

  defp disable_route(token, device_id, ours) do
    case ApiClient.routes_get(token, device_id) do
      {:ok, routes} ->
        if ours in routes.enabled do
          ApiClient.routes_set(token, device_id, List.delete(routes.enabled, ours))
        else
          :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp route_cidr(resolver_ip), do: "#{resolver_ip}/32"

  # ------------------------------------------------------------------
  # The API token credential (ADR-0040 §5)
  # ------------------------------------------------------------------

  @doc """
  Writes the org's Tailscale API token to the gateway's api-credential
  Secret and returns its ref (§5's intake — `SetAccessApiToken`'s
  cluster leg). Same discipline as the authkey pair: the row stores the
  Secret's NAME, the token never reaches Postgres, no user surface
  reads it back.
  """
  @spec write_api_credential(AccessGateway.t(), String.t()) ::
          {:ok, %{api_token_secret_ref: String.t()}} | {:error, term()}
  def write_api_credential(%AccessGateway{} = gateway, token) do
    with {:ok, kubeconfig} <- kubeconfig() do
      name = api_credential_secret_name(gateway)

      case Secret.create(kubeconfig, access_namespace(), name, %{"TS_API_TOKEN" => token}) do
        {:ok, _secret} -> {:ok, %{api_token_secret_ref: name}}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Reads the API token back — internal only (claiming needs it for the
  Tailscale API calls). No user surface returns it (§5).
  """
  @spec read_api_credential(AccessGateway.t()) :: {:ok, String.t()} | {:error, term()}
  def read_api_credential(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      case Secret.get_data(kubeconfig, access_namespace(), api_credential_secret_name(gateway)) do
        {:ok, %{"TS_API_TOKEN" => token}} when is_binary(token) and token != "" ->
          {:ok, token}

        {:ok, _malformed} ->
          {:error, :api_token_malformed}

        {:error, %Error{reason: :not_found}} ->
          {:error, :no_api_token}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # ------------------------------------------------------------------
  # refresh_routes/1
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def refresh_routes(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      # Both flip directions land here (see the behaviour's doc): the
      # whole config is regenerated from the routes' current rows, so a
      # concurrent detach cannot be resurrected by a stale partial write.
      write_serve_config(kubeconfig, access_namespace(), gateway)
    end
  end

  # ------------------------------------------------------------------
  # update_credential/2
  # ------------------------------------------------------------------

  @impl FluxVale.Infrastructure.AccessProvider
  def update_credential(%AccessGateway{state: :provisioning} = gateway, auth_key) do
    # Drift repair, owner-triggered: a :provisioning row whose objects
    # never landed (or were lost) has no Deployment to restart — the
    # restart path would 404 and strand the row with no owner way out.
    # Re-apply the objects instead: provision_gateway is SSA-idempotent
    # and writes the key on the way, the create path's same call.
    case provision_gateway(gateway, auth_key) do
      {:ok, _ref} -> :ok
      {:error, _reason} = error -> error
    end
  end

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
  def cleanup_failed_provision(%AccessGateway{} = gateway) do
    # The CREATE path's rollback only. `:provision`'s drift repair reads
    # its key from this Secret, so this is deliberately a separate entry
    # point — `provision_gateway/2` must never delete it on failure.
    with {:ok, kubeconfig} <- kubeconfig() do
      namespace = access_namespace()

      # Delete the keys first: they are the only objects a stranger
      # could use if the rest of the cleanup fails and the row is
      # already gone. The api-credential rides the same rule (P1-1: no
      # orphaned API key from any exit) — usually a 404, since a create
      # that failed never got a token.
      with :ok <- safe_delete_secret(kubeconfig, namespace, credential_secret_name(gateway)),
           :ok <- safe_delete_secret(kubeconfig, namespace, api_credential_secret_name(gateway)),
           :ok <- safe_delete_secret(kubeconfig, namespace, serve_secret_name(gateway)) do
        safe_delete_pvc(kubeconfig, namespace, state_claim_name(gateway))
      end
    end
  end

  @impl FluxVale.Infrastructure.AccessProvider
  def teardown_gateway(%AccessGateway{} = gateway) do
    with {:ok, kubeconfig} <- kubeconfig() do
      namespace = access_namespace()

      # P1-1's rule, stated: no dangling tailnet state and no orphaned
      # API key, from EVERY exit. The unclaim-all goes FIRST (the
      # detach-fails-teardown discipline: a failure FAILS the teardown,
      # Oban retries, and every limb is idempotent, so the retry
      # converges instead of compounding) — a destroyed row with a live
      # claim would leave the owner's tailnet resolving a hostname
      # nothing answers for, and the API key would outlive its row.
      with :ok <- unclaim_all(gateway),
           # Detach every instance first: each detach re-admits only
           # same-namespace and rewrites the serve config, so an
           # instance can never be left pointing at a gateway that no
           # longer exists.
           #
           # A detach failure FAILS the teardown, deliberately.
           # Collecting and ignoring it would hard-delete the row and
           # then report success while an instance kept a policy entry
           # pointing at this gateway's labels — residue nothing would
           # ever return to the private floor (the route rows die in
           # the FK cascade, so no later detach could find it). Oban
           # retries; detach and the deletes are both idempotent, so
           # the retry converges instead of compounding.
           attached = AccessGateway.attached_instances(gateway),
           :ok <- detach_all(gateway, attached) do
        delete_objects(kubeconfig, namespace, gateway)
      end
    end
  end

  # Reverts EVERY claim this gateway holds, through the same
  # tailnet-scoped logic unclaim_domain uses (the split-DNS route is
  # nil'd unless another gateway on the recorded tailnet still holds
  # the domain; the /32 comes off with the last claim). Each step sees
  # the claims map with the earlier steps' entries REMOVED (the struct
  # is re-pointed per iteration) — the stale full map would make every
  # step but the first keep the /32. A gateway with claims but no
  # readable token FAILS the teardown honestly — the entries are real
  # tailnet state, and the owner's recovery is a fresh token, then opt
  # out again.
  defp unclaim_all(%AccessGateway{dns_claims: claims} = gateway) when is_map(claims) do
    domains = Map.keys(claims)

    result =
      Enum.reduce_while(domains, {:ok, claims}, fn domain, {:ok, remaining} ->
        step_unclaim(%{gateway | dns_claims: remaining}, domain, remaining)
      end)

    case result do
      {:ok, _remaining} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp unclaim_all(_gateway), do: :ok

  defp step_unclaim(gateway, domain, remaining) do
    case unclaim_domain(gateway, domain) do
      :ok ->
        {:cont, {:ok, Map.delete(remaining, domain)}}

      {:error, reason} ->
        {:halt, {:error, {:unclaim_failed, domain, reason}}}
    end
  end

  defp detach_all(gateway, attached) do
    Enum.reduce_while(attached, :ok, fn instance, :ok ->
      case detach_instance(gateway, instance) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:detach_failed, instance.id, reason}}}
      end
    end)
  end

  defp delete_objects(kubeconfig, namespace, gateway) do
    with :ok <- safe_delete_deployment(kubeconfig, namespace, gateway),
         :ok <- safe_delete_secret(kubeconfig, namespace, serve_secret_name(gateway)),
         :ok <- safe_delete_secret(kubeconfig, namespace, credential_secret_name(gateway)),
         :ok <- safe_delete_secret(kubeconfig, namespace, api_credential_secret_name(gateway)) do
      safe_delete_pvc(kubeconfig, namespace, state_claim_name(gateway))
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
  #
  # The Web keys need the tailnet's MagicDNS suffix; a gateway row that
  # predates the column (nil domain) with an attached route is refused
  # loudly — writing the old `"<hostname>.${TS_CERT_DOMAIN}"` literal
  # back would resurrect the bug this shape fixed. An EMPTY route list
  # still writes: the config carries no Web key, so the domain is
  # unused and the nothing-served-yet posture keeps converging.
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

    with :ok <- ensure_tailnet_domain(gateway, entries) do
      config = ServeConfig.build(gateway.hostname, gateway.tailnet_domain, entries)

      case Secret.create(kubeconfig, namespace, serve_secret_name(gateway), %{
             @serve_file => ServeConfig.encode(config)
           }) do
        {:ok, secret} -> {:ok, secret}
        {:error, _reason} = error -> error
      end
    end
  end

  # Only the migration-window row can be here: the attribute is required
  # on create, so every row made after the column lands carries a
  # domain (the re-paste form backfills the pre-existing one).
  defp ensure_tailnet_domain(%{tailnet_domain: nil}, [_route | _more]),
    do: {:error, :tailnet_domain_missing}

  defp ensure_tailnet_domain(_gateway, _entries), do: :ok

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

  # The attach failed after the row may have landed: remove it so a retry
  # starts clean. A leftover row would hold a port and — worse — read as
  # the owner's consent for a wake the owner never got service for. The
  # policy and serve config are re-derived from the rows, so removing the
  # row is enough for both; the original error is preserved.
  #
  # Two distinct failures reach here and they must NOT be treated alike:
  #
  # - a cluster limb failed AFTER this attempt's row committed (four
  #   args) — that row is ours, and it must go;
  # - `create_route/3` itself failed (three args) — nothing of ours
  #   landed, and the row the lookup finds belongs to a concurrent
  #   attach that WON the unique index. Deleting it would tear down the
  #   winner's committed pairing (both racers share one gateway — the
  #   resource is unique per org — so a gateway-scoped match cannot tell
  #   them apart; only "did this attempt create it" can).
  defp cleanup_failed_attach(gateway, instance, error, _route) do
    # Best-effort: the original error is what the caller surfaces and
    # retries on.
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

  # The route row was never ours (see the four-arg clause above): the
  # instance already has a pairing, and it belongs to whoever committed
  # first. Leave it alone — a retry converges on it via `existing_route`.
  defp cleanup_failed_attach(_gateway, _instance, error), do: error

  # Cleanup's delete: only the pairing THIS attach created. A concurrent
  # attach that won the unique index must keep its route, so a bare
  # delete-by-instance would tear down the winner's work.
  defp delete_route(gateway, instance) do
    case route_for(instance) do
      %AccessRoute{gateway_id: gateway_id} = route when gateway_id == gateway.id ->
        AccessRoute.destroy(route, authorize?: false)

      # Rows are unique per instance and this call runs only after our own
      # create committed, so seeing another gateway's row here means a
      # writer swapped it mid-flight — leaving it is the safe answer, and
      # the branch exists so the mismatch can never delete foreign state.
      # coveralls-ignore-next-line race only: our own create just committed this row
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
    case apply_policy(kubeconfig, instance, []) do
      :ok -> :ok
      # Namespace gone — the posture already holds (the object-delete stance
      # from teardown_instance safe_delete). We only do this on DISADMIT; attach
      # still fails on 404.
      {:error, %FluxVale.Clients.K8s.Error{reason: :not_found}} -> :ok
      {:error, _reason} = error -> error
    end
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
        observed = classify(status, gateway)
        reconcile_claim_credential(observed, gateway)

      # No Deployment. A row still in :provisioning has simply not had its
      # apply land yet; a row past that (:active/:needs_attention) has
      # LOST its Deployment, which is drift — reporting :provisioning
      # there would leave the panel saying "Setting up access" and (for
      # :active) keep metering a pod that does not exist.
      {:error, %Error{reason: :not_found}} ->
        if gateway.state == :provisioning do
          {:ok, %{state: :provisioning, message: "Setting up access"}}
        else
          # #179's friendly-vs-k8s split: this message renders on the
          # panel (the row's status_message), so it names no platform
          # term — and only affordances the panel backs. With
          # update_credential's drift repair, a fresh key re-applies the
          # lost objects, so reconnect IS the honest next step here (no
          # support link exists to point at).
          {:ok,
           %{
             state: :needs_attention,
             message: "Not connected — your access setup was lost; reconnect with a fresh key"
           }}
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

  # ------------------------------------------------------------------
  # The claims drift limb (ADR-0040 §5)
  # ------------------------------------------------------------------

  # The drift copy, keyed by the API's verdict — the ONE source (the
  # claim operation reads it through the provider seam, so the panel can
  # never show two different sentences for the same rejection).
  #
  # 401 (:unauthorized): expired and revoked present identically (§5 —
  # a key expires ≤90 days by design, so this WILL happen); "rejected"
  # is the one honest word for both.
  # 403 (:forbidden): authenticated but scope-less — the copy NAMES the
  # three scopes claiming needs, because a fresh key without them
  # fails the same way again.
  @token_rejected_message "Your Tailscale API key was rejected — paste a fresh one"

  @token_scope_message ~s(Your Tailscale API key is missing the permissions FluxVale needs ) <>
                         ~s(dns, devices:routes, devices:core:read — paste a fresh key with them)

  @spec token_drift_message(:unauthorized | :forbidden) :: String.t()
  def token_drift_message(:unauthorized), do: @token_rejected_message
  def token_drift_message(:forbidden), do: @token_scope_message

  # Only a gateway with a token ref reaches the limb (claims alone
  # cannot be verified; nothing provable either way). One-shot per
  # observation pass — no retry loop (the honest one-shot; the next
  # tick re-decides). A 401/403 lands :needs_attention with the
  # verdict's copy; any OTHER check failure is logged and the
  # pod-level observation stands — a flaky read must not flap a row.
  defp reconcile_claim_credential({:ok, %{state: :active}} = observed, gateway) do
    if gateway.api_token_secret_ref != nil do
      with {:ok, token} <- read_api_credential(gateway),
           :ok <- check_token(token, gateway) do
        reconcile_and_default_claim(token, gateway)
        observed
      else
        {:error, :unauthorized} ->
          {:ok, %{state: :needs_attention, message: token_drift_message(:unauthorized)}}

        {:error, :forbidden} ->
          {:ok, %{state: :needs_attention, message: token_drift_message(:forbidden)}}

        {:error, reason} ->
          Logger.warning(
            "Access gateway #{gateway.id} API token check failed (no drift): #{inspect(reason)}"
          )

          observed
      end
    else
      observed
    end
  end

  defp reconcile_claim_credential(observed, _gateway), do: observed

  # The claims reconcile limb (P2-4 + P2-6), plus the RULED default-on
  # platform claim (ADR-0040 §3): a gateway that is :active with a
  # working token claims the org's platform domain automatically — the
  # base-domain default the ADR ruled, made real before S5's UI.
  #
  # Per pass (one-shot): converges stored claim IPs to the configured
  # resolver (re-PATCH + re-apply the Deployment — a TS_ROUTES diff is
  # a pod-template change, so the restart is how the new /32 reaches
  # the node), re-unions the /32 when the enabled list lost it (the
  # routes POST REPLACES the list, so a racing writer can drop ours —
  # this closes that window within a tick), and claims the platform
  # domain when nothing else did. Failures stand down logged: a flaky
  # read must not flap a row, and the next tick re-decides.
  defp reconcile_and_default_claim(token, gateway) do
    converged = converge_entries(token, gateway, gateway.dns_claims || %{})
    final = maybe_claim_platform_domain(token, gateway, converged)
    land_reconciled(gateway, final)
  end

  defp land_reconciled(gateway, claims) do
    # nil and %{} are the same posture — an empty reconcile must not
    # turn into a write that merely normalizes the column.
    if claims == (gateway.dns_claims || %{}) do
      :ok
    else
      write_reconciled(gateway, claims)
    end
  end

  defp write_reconciled(gateway, claims) do
    case AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Access gateway #{gateway.id} claims reconcile write skipped: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Converges every entry's recorded IP to the configured resolver
  # (P2-4): a drifted IP gets one PATCH (the native per-domain upsert)
  # and — when anything drifted — ONE Deployment re-apply, because a
  # TS_ROUTES diff is a pod-template change and the restart is how the
  # new /32 reaches the node. Returns the (possibly updated) claims map.
  # The comparison and the PATCH use the BARE resolver IP — the same
  # unit the claim entries record; only the route re-union speaks CIDR.
  defp converge_entries(token, gateway, claims) do
    case resolver_ip() do
      {:ok, ip} ->
        {converged, drifted?} = converge_entry_ips(token, claims, ip)
        re_union_route(token, gateway, route_cidr(ip))

        if drifted? do
          reapply_deployment(gateway)
        end

        converged

      _unset ->
        claims
    end
  end

  defp converge_entry_ips(token, claims, ours_ip) do
    Enum.reduce(claims, {claims, false}, fn {domain, claim}, acc ->
      converge_one(token, domain, claim, ours_ip, acc)
    end)
  end

  defp converge_one(token, domain, claim, ours_ip, {claims, drifted?} = acc) do
    if is_map(claim) and is_binary(claim["ip"]) and claim["ip"] != ours_ip do
      converge_drifted(token, domain, claim, ours_ip, {claims, drifted?})
    else
      acc
    end
  end

  defp converge_drifted(token, domain, claim, ours_ip, {claims, drifted?}) do
    case ApiClient.split_dns_patch(token, %{domain => [ours_ip]}) do
      :ok ->
        {Map.put(claims, domain, Map.put(claim, "ip", ours_ip)), true}

      {:error, reason} ->
        Logger.warning(
          "Access gateway claim #{domain}: split-DNS convergence failed (stands down): " <>
            inspect(reason)
        )

        {claims, drifted?}
    end
  end

  # P2-6: the routes POST REPLACES the enabled list, so any racing
  # writer can drop our /32 between claims. One read here re-unions it
  # within a tick; when it is still present this is a single GET.
  defp re_union_route(token, gateway, ours) do
    case tailnet_node(token, gateway) do
      {:ok, %{id: device_id}} ->
        re_union_enabled(token, device_id, ours, gateway)

      {:error, reason} ->
        Logger.warning(
          "Access gateway #{gateway.id}: node lookup failed (stands down): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp re_union_enabled(token, device_id, ours, gateway) do
    case ApiClient.routes_get(token, device_id) do
      {:ok, routes} ->
        ensure_unioned(token, device_id, routes, ours, gateway)

      {:error, reason} ->
        Logger.warning(
          "Access gateway #{gateway.id}: routes read failed (stands down): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_unioned(token, device_id, routes, ours, gateway) do
    if ours in routes.enabled do
      :ok
    else
      case ApiClient.routes_set(token, device_id, Enum.uniq([ours | routes.enabled])) do
        :ok ->
          Logger.warning(
            "Access gateway #{gateway.id}: /32 missing from enabled routes — re-united"
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "Access gateway #{gateway.id}: /32 re-union failed (stands down): #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  # One SSA re-apply of the pod template: idempotent, and the restart
  # it triggers is what makes a moved resolver IP reach the node.
  defp reapply_deployment(gateway) do
    case kubeconfig() do
      {:ok, kubeconfig} ->
        manifest = deployment_manifest(gateway, access_namespace())

        case Deployment.apply_manifest(kubeconfig, manifest) do
          {:ok, _deployment} ->
            Logger.warning(
              "Access gateway #{gateway.id}: resolver IP moved — Deployment re-applied"
            )

            :ok

          {:error, reason} ->
            Logger.warning(
              "Access gateway #{gateway.id}: Deployment re-apply failed (stands down): " <>
                inspect(reason)
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "Access gateway #{gateway.id}: no cluster for the Deployment re-apply (stands down): " <>
            inspect(reason)
        )

        :ok
    end
  end

  # The RULED default-on claim (ADR-0040 §3): a gateway that is active
  # with a working token claims the org's platform domain automatically
  # — the owner's base-domain default experience, made real before S5's
  # UI. A shared tailnet converges by nature: claim_domain sees the
  # route and the split-DNS value already right and writes nothing.
  defp maybe_claim_platform_domain(_token, gateway, claims) do
    with {:ok, resolver_ip} <- resolver_ip(),
         %AccessDomain{domain: name, state: :verified} <-
           platform_domain(gateway.organization_id),
         false <- Map.has_key?(claims, name) do
      case claim_domain(gateway, name, resolver_ip) do
        {:ok, _claimed} ->
          Logger.warning(
            "Access gateway #{gateway.id}: platform domain #{name} claimed (default-on)"
          )

          Map.put(claims, name, %{"ip" => resolver_ip, "tailnet" => gateway.tailnet_domain})

        {:error, reason} ->
          Logger.warning(
            "Access gateway #{gateway.id}: default platform claim failed (stands down): " <>
              inspect(reason)
          )

          claims
      end
    else
      _no_resolver_or_platform_row_or_already_claimed ->
        claims
    end
  end

  # The org's platform row — born :verified (the fleet wildcard covers
  # it), so no verify gate beyond the state match.
  defp platform_domain(organization_id) do
    case AccessDomain
         |> Ash.Query.filter(
           organization_id == ^organization_id and kind == :platform and state == :verified
         )
         |> Ash.read_one(authorize?: false) do
      {:ok, domain} ->
        domain

      # DB-down: a real read failure cannot be exercised in the
      # sandbox; standing down (nil = no platform row this tick) is the
      # honest answer, and the observe pass's outer error handling owns
      # genuine DB outages via Oban retries.
      # coveralls-ignore-next-line
      {:error, _reason} ->
        nil
    end
  end

  defp resolver_ip do
    case Application.get_env(:flux_vale, :access_dns) do
      config when is_list(config) ->
        {:ok, Keyword.fetch!(config, :resolver_ip)}

      _unset ->
        {:error, :resolver_unconfigured}
    end
  end

  # The cheapest scoped read (devices:core:read) doubles as the probe.
  defp check_token(token, gateway) do
    case ApiClient.devices_lookup(token, gateway.hostname) do
      {:ok, _device} ->
        :ok

      {:error, :unauthorized} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The cheapest scoped read (devices:core:read) doubles as the probe.
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
      "env" => env(gateway),
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

  defp env(gateway) do
    base = [
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
    ]

    base ++ resolver_route_env()
  end

  # ADR-0040 §3: the gateway advertises the shared access-DNS
  # resolver's /32, so tailnet devices can route to the resolver once
  # the claim approves the route on the node. Config-gated like the
  # tunnel limb — local stacks (no `:access_dns`) omit the env and the
  # manifest is exactly what ADR-0039 shipped.
  defp resolver_route_env do
    case resolver_route() do
      nil ->
        []

      cidr ->
        [%{"name" => "TS_ROUTES", "value" => cidr}]
    end
  end

  # The advertised /32 — one Service ClusterIP, never a wider slice
  # (§12's subnet-route rule). Shared by the manifest, the reconcile
  # limb and the unclaim's route fallback, so the three can never
  # disagree.
  defp resolver_route do
    case resolver_ip() do
      {:ok, ip} -> route_cidr(ip)
      _unset -> nil
    end
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
  defp selector_labels(gateway), do: InstanceK8s.gateway_pod_labels(gateway.id)

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
    InstanceK8s.gateway_access_namespace()
  end
end
