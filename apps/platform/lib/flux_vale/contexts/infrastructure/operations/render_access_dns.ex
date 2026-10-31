defmodule FluxVale.Infrastructure.Operations.RenderAccessDNS do
  @moduledoc """
  The resolution plane (ADR-0040 §4/§8): renders the CoreDNS Corefile
  the fleet's access-DNS deployment (fleet #122) mounts, and writes it
  to one ConfigMap in the access namespace. Exposure becomes a
  resolution question — a claimed domain's attached private hostnames
  answer the CLAIMING gateway's tailnet IP for THAT gateway's queries
  only (per-gateway CoreDNS views, keyed on the query's source = the
  gateway pod IP); everything else falls through to public recursion,
  so public hostnames behave identically on and off the tailnet.

  The shape of one gateway's view, per claimed domain:

  - `view <gw-short>` matches queries arriving FROM the gateway pod
    (`incidr(client_ip(), <pod-ip>/32)`) — org A's hostnames never
    answer for org B's gateway-sourced queries (§4's scoping rule);
  - the `hosts` entries are EXACTLY that gateway's org's attached +
    private instances' hostnames on the claimed domain, each answered
    with the gateway's TAILNET IP (the address a tailnet device can
    dial — the pod IP is only the view's SOURCE key);
  - `forward .` hands every other name in the zone to public recursion
    (no hostname is dark that shouldn't be).

  Blocks are ordered gateway-views BEFORE the per-domain default
  (un-viewed) blocks — first match wins, and the default sends any
  no-gateway source (in-cluster strays, misroutes) straight to public
  recursion: no private answers without a gateway on the path.

  **The view is derived state.** The arms (EdgeRoutes) and the claims
  (`dns_claims`) are the source of truth; every `call/1` is
  best-effort AFTER a primary write commits — a failed render never
  fails the attach/detach/toggle/claim it rode in on, and the 15-minute
  verify pass re-renders (the pod-move refresher and the drift healer).
  A gateway between restarts has no pod, its views are omitted, and it
  is dark for DNS until the next pass — the documented window. Nothing
  is cached.

  No ConfigMap consumers exist yet (fleet #122 mounts it) — the write
  is harmless until then.
  """

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.ConfigMap
  alias FluxVale.Clients.K8s.Resources.Pod
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.InstanceK8s

  require Ash.Query
  require Logger

  # Public recursion for everything a view does not answer (§4): public
  # hostnames keep resolving identically on-tailnet, unknown names stay
  # strangers' business. Same pair in every block — one constant.
  @public_forwarders "1.1.1.1 8.8.8.8"

  # The hosts plugin answers its entries in-process; `ttl 5` keeps a
  # moved gateway IP converging client-side in seconds (the resolver's
  # own zero-cache posture — the plugin's 3600 default would freeze a
  # pod move for an hour). `fallthrough` hands an in-zone MISS to the
  # block's forward: without it the hosts plugin answers the zone and
  # the fallback is dead code.
  @hosts_ttl 5

  # The ConfigMap key the fleet deployment mounts (the WHOLE Corefile in
  # one key — the contract the deployment follows).
  @corefile_key "Corefile"

  # The object name, from config `:flux_vale, :access_dns, :zone_configmap`
  # (default "access-dns-zones").
  @default_zone_configmap "access-dns-zones"

  @typedoc """
  Per-gateway resolver facts, gathered fresh each pass: the gateway's
  current pod IP (the view's SOURCE key) and its tailnet IP (the
  ANSWER). Keyed by gateway id.
  """
  @type resolver_data :: %{
          optional(Ash.UUID.t()) => %{pod_ip: String.t(), tailnet_ip: String.t()}
        }

  @typedoc "One view block's inputs — a (gateway, claimed domain) pair."
  @type view :: %{
          domain: String.t(),
          view_name: String.t(),
          pod_ip: String.t(),
          tailnet_ip: String.t(),
          hostnames: [String.t()]
        }

  @doc """
  The complete Corefile for the CURRENT claims: every view block, then
  the default blocks. Pure string building — the golden-test surface.
  The defaults are keyed on the CLAIMED domains (which queries can
  arrive for), never on which views happened to render — a dark
  gateway must not take its domain's default block down with it.

  The renderer may NEVER emit an unloadable file: the zero-claims case
  is a valid placeholder (below), not an empty string.
  """
  @spec corefile([view()], [String.t()]) :: String.t()
  def corefile(views, claimed_domains)

  def corefile([], []) do
    # An EMPTY Corefile is not a config CoreDNS can load, so the
    # zero-claims render emits an inert root recursor instead: while no
    # split-DNS route points here, nothing resolves through it (the
    # tailnet's own DNS answers everything); the file reloads cleanly
    # the day a claim lands.
    """
    # no claims
    .:53 {
        forward . #{@public_forwarders}
    }
    """
  end

  def corefile(views, claimed_domains) do
    view_blocks =
      views
      |> Enum.sort_by(&{&1.domain, &1.view_name})
      |> Enum.map(&view_block/1)

    join_blocks(view_blocks ++ default_blocks(claimed_domains))
  end

  @doc """
  Gathers the resolver data fresh: each claiming gateway's current pod
  IP (pods listed by the gateway's own labels in the access namespace)
  and tailnet IP (the provider's API client, token via the provider —
  the client's reach is unchanged). A gateway with no running pod, no
  readable token, or a failed device lookup is OMITTED (warning logged)
  — dark until the next pass, the documented window.
  """
  @spec gather() :: resolver_data()
  def gather do
    case claiming_gateways() do
      [] ->
        %{}

      gateways ->
        case K8s.kubeconfig() do
          {:ok, kubeconfig} ->
            namespace = InstanceK8s.gateway_access_namespace()

            gateways
            |> Map.new(&gateway_data(kubeconfig, namespace, &1))
            |> drop_omitted()

          # No cluster to read pods from: gather nothing rather than
          # half-guess — the previous view stands until the next pass.
          # Tested at the seam (the kubeconfig stub's error tuple).
          {:error, reason} ->
            Logger.warning(
              "Access DNS: no cluster kubeconfig — gathering nothing this pass: #{inspect(reason)}"
            )

            %{}
        end
    end
  end

  @doc """
  Renders the Corefile from the claims (read `authorize?: false` — the
  system seam) and the gathered resolver data. No writes.
  """
  @spec render(resolver_data()) :: String.t()
  def render(resolver_data) do
    gateways = claiming_gateways()

    views = Enum.flat_map(gateways, &gateway_views(&1, resolver_data))
    claimed = Enum.flat_map(gateways, &claimed_domain_names/1)

    corefile(views, claimed)
  end

  @doc """
  Gather → render → write, best-effort. ALWAYS `:ok` — a failure is
  logged and the previous view stands until the next pass (see the
  moduledoc's derived-state stance). `opts` may carry `resolver_data:`
  (a precomputed map — the tests' seam and a caller that already
  gathered).
  """
  @spec call(keyword()) :: :ok
  def call(opts \\ []) do
    data = Keyword.get(opts, :resolver_data) || gather()
    corefile = render(data)
    write(corefile)
  rescue
    # The derived-state stance: the pass (and every flip hook) must move
    # on. Ash raises on read failures; the K8s helpers can raise on
    # config errors — none of it may fail a primary operation.
    error ->
      Logger.warning(
        "Access DNS: render pass failed (view stays until the next pass): " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # ------------------------------------------------------------------
  # Views — the claims, read system-side
  # ------------------------------------------------------------------

  defp claiming_gateways do
    AccessGateway
    |> Ash.Query.filter(not is_nil(dns_claims))
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(map_size(&1.dns_claims || %{}) > 0))
    |> Enum.sort_by(& &1.id)
  end

  defp gateway_views(gateway, resolver_data) do
    case Map.get(resolver_data, gateway.id) do
      nil ->
        Logger.warning(
          "Access DNS: gateway #{gateway.id} has claims but no resolver data (no running pod " <>
            "or device lookup failed) — its views are omitted; dark until the next pass"
        )

        []

      %{pod_ip: pod_ip, tailnet_ip: tailnet_ip} ->
        gateway
        |> claimed_domains()
        |> Enum.map(fn {name, domain} ->
          %{
            domain: name,
            view_name: view_name(gateway),
            pod_ip: pod_ip,
            tailnet_ip: tailnet_ip,
            hostnames: hostnames(gateway, domain, name)
          }
        end)
    end
  end

  # The gateway's claimed domains that may ANSWER: the org's row for the
  # claimed name in a routable state — `:verified`, or `:needs_attention`
  # (the healing state; the same mirror the TLS clause routes). A
  # `:suspended` claim (the billing ladder's demotion) keeps its tailnet
  # route but answers NOTHING here — honest dark, the domain-scoped arm's
  # DNS half.
  defp claimed_domains(gateway) do
    gateway.dns_claims
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&claim_answerable(gateway, &1))
    |> Enum.reject(&is_nil/1)
  end

  # The DEFAULT blocks' key set: every claimed name, state aside — the
  # split-DNS route sends the domain's queries HERE whatever the row's
  # state, so the no-gateway source always has its public-recursion
  # fallback.
  defp claimed_domain_names(gateway) do
    gateway.dns_claims
    |> Map.keys()
    |> Enum.sort()
  end

  defp claim_answerable(gateway, name) do
    query =
      Ash.Query.filter(
        AccessDomain,
        organization_id == ^gateway.organization_id and domain == ^name
      )

    case Ash.read_one(query, authorize?: false) do
      {:ok, %AccessDomain{state: state} = domain} when state in [:verified, :needs_attention] ->
        {name, domain}

      {:ok, %AccessDomain{state: state} = _dark} ->
        Logger.warning(
          "Access DNS: gateway #{gateway.id} still holds the claim for #{name} but its domain " <>
            "row is #{inspect(state)} — answering nothing (dark is the posture)"
        )

        nil

      # The row is gone but the claim stands (a remove that lost the
      # claims write) — answer nothing; the unclaim path re-renders.
      {:ok, nil} ->
        Logger.warning(
          "Access DNS: gateway #{gateway.id} claims #{name} but no domain row exists — " <>
            "answering nothing"
        )

        nil

      # coveralls-ignore-start - defensive: a DB read failure (the outage
      # ExUnit cannot stage — DBConnection reconnects by design) — the
      # arm answers nothing this pass and the next tick re-decides.
      {:error, reason} ->
        Logger.warning(
          "Access DNS: domain read for #{name} failed (answering nothing this pass): " <>
            inspect(reason)
        )

        nil
        # coveralls-ignore-stop
    end
  end

  # The org's attached + private instances' hostnames under THIS domain —
  # the exact answer set. The pairing row is "attached" (the same source
  # the policy spec and the edge arms read); exposure is re-checked on
  # the loaded instance (a public attached row keeps no private answer).
  defp hostnames(gateway, domain, name) do
    gateway.id
    |> attached_private_instances(gateway.organization_id)
    |> Enum.flat_map(&hostname_rows(&1.id, domain.id))
    |> Enum.map(&"#{&1.label}.#{name}")
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp attached_private_instances(gateway_id, organization_id) do
    AccessRoute
    |> Ash.Query.filter(gateway_id == ^gateway_id)
    |> Ash.Query.load(:instance)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.instance)
    |> Enum.filter(&(&1.exposure == :private and &1.organization_id == organization_id))
  end

  defp hostname_rows(instance_id, domain_id) do
    InstanceHostname
    |> Ash.Query.filter(instance_id == ^instance_id and access_domain_id == ^domain_id)
    |> Ash.read!(authorize?: false)
  end

  # The object_name short_id discipline (the RANDOM TAIL of the id, never
  # the uuid head — the AccessRoute/EdgeRoutes rule): a uuid v7's head is
  # a millisecond timestamp, identical for rows minted in the same window.
  defp view_name(gateway) do
    gateway.id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(-10, 10)
  end

  # ------------------------------------------------------------------
  # Gather — pod IPs + tailnet IPs
  # ------------------------------------------------------------------

  defp gateway_data(kubeconfig, namespace, gateway) do
    with {:ok, pod_ip} <- pod_ip(kubeconfig, namespace, gateway),
         {:ok, tailnet_ip} <- tailnet_ip(gateway) do
      {gateway.id, %{pod_ip: pod_ip, tailnet_ip: tailnet_ip}}
    else
      {:error, reason} ->
        Logger.warning(
          "Access DNS: gateway #{gateway.id} omitted from the views this pass: #{inspect(reason)}"
        )

        {gateway.id, nil}
    end
  end

  # The gateway's CURRENT pod IP — a pod move is invisible to the claims,
  # so the gather re-reads every pass (the 15-min refresher's reason to
  # exist). Terminating pods are excluded (their IP is a REUSE window —
  # the address may already belong to the replacement); among survivors
  # the NEWEST wins. Only-Terminating = the no-pod omission path (dark
  # until the next pass, the documented window). Residual: a survivor
  # can still predate a just-landed replacement for one render cadence —
  # shrunk from unbounded to 15 minutes, and the pass heals it.
  defp pod_ip(kubeconfig, namespace, gateway) do
    labels = InstanceK8s.gateway_pod_labels(gateway.id)

    case Pod.list_by_labels(kubeconfig, namespace, labels) do
      {:ok, pods} ->
        survivors =
          Enum.filter(pods, fn pod ->
            not Pod.terminating?(pod) and Pod.running_ip(pod) != nil
          end)

        case Enum.sort_by(survivors, &Pod.started_at/1, {:desc, DateTime}) do
          [] -> {:error, :no_running_pod}
          [newest | _rest] -> {:ok, Pod.running_ip(newest)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The tailnet IP comes from the tailnet API (the only place the
  # platform can read one) through the provider's own credential path —
  # the client's reach is not widened, and the token never logs.
  defp tailnet_ip(gateway) do
    with {:ok, token} <- Tailscale.read_api_credential(gateway),
         {:ok, %{tailscale_ips: ips}} <- ApiClient.devices_lookup(token, gateway.hostname) do
      first_ipv4(ips)
    end
  end

  # The A record needs a REAL IPv4 (100.x.y.z) — validated, not
  # sniffed: `:inet.parse_address` is the verdict, so a v6-only node or
  # a malformed payload omits the gateway (warned, next pass re-decides)
  # instead of freezing an unloadable answer into the hosts block.
  defp first_ipv4(ips) do
    case Enum.find(ips, &valid_ipv4?/1) do
      nil -> {:error, :no_tailnet_ipv4}
      ip -> {:ok, ip}
    end
  end

  # All-binaries by construction: the client's own addresses extraction
  # filters non-strings before the list gets here, so a non-binary
  # clause would be dead code.
  defp valid_ipv4?(ip) do
    charlist = String.to_charlist(ip)
    parsed = :inet.parse_address(charlist)

    case parsed do
      {:ok, {_a, _b, _c, _d}} -> true
      _not_an_ipv4 -> false
    end
  end

  defp drop_omitted(data) do
    data
    |> Enum.reject(fn {_id, entry} -> is_nil(entry) end)
    |> Map.new()
  end

  # ------------------------------------------------------------------
  # The Corefile — pure string building
  # ------------------------------------------------------------------

  defp view_block(view) do
    header = "#{view.domain}:53 {\n    view #{view.view_name} {\n"
    expr = "        expr incidr(client_ip(), \"#{view.pod_ip}/32\")\n    }\n"
    hosts = hosts_block(view.hostnames, view.tailnet_ip)

    header <> expr <> hosts <> "    forward . #{@public_forwarders}\n}\n"
  end

  # The hosts plugin answers its entries and — via `fallthrough` —
  # hands an in-zone miss to the block's forward (without it a miss
  # would SERVFAIL: the hosts plugin owns the zone it loaded). `ttl 5`
  # keeps a moved gateway IP converging client-side in seconds.
  defp hosts_block([], _tailnet_ip), do: ""

  defp hosts_block(hostnames, tailnet_ip) do
    entries = Enum.map_join(hostnames, "\n", &"        #{tailnet_ip} #{&1}")

    "    hosts {\n" <>
      entries <> "\n        ttl #{@hosts_ttl}\n        fallthrough\n    }\n"
  end

  # The DEFAULT (un-viewed) blocks — one per claimed domain, any source
  # that is no gateway gets public recursion only. AFTER every view
  # block: first match wins, gateways must land in their views.
  defp default_blocks(claimed_domains) do
    claimed_domains
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&default_block/1)
  end

  defp default_block(domain) do
    "#{domain}:53 {\n    forward . #{@public_forwarders}\n}\n"
  end

  # Blocks already end in \n; a blank line separates them, and the whole
  # file ends with exactly one newline. No views → the empty Corefile
  # (nothing claimed, nothing answered — the fleet deployment's problem
  # how to boot on that, not ours).
  # No empty-list clause: the zero-claims case returns the placeholder
  # before the join, and any claims imply at least one default block —
  # an empty join input is unreachable.
  defp join_blocks(blocks) do
    Enum.map_join(blocks, "\n\n", &String.trim_trailing(&1, "\n")) <> "\n"
  end

  # ------------------------------------------------------------------
  # The one cluster write
  # ------------------------------------------------------------------

  defp write(corefile) do
    with {:ok, kubeconfig} <- K8s.kubeconfig(),
         {:ok, _body} <-
           ConfigMap.create(
             kubeconfig,
             InstanceK8s.gateway_access_namespace(),
             zone_configmap(),
             %{@corefile_key => corefile}
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "Access DNS: ConfigMap write failed — the previous view stands until the next pass: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp zone_configmap do
    case Application.get_env(:flux_vale, :access_dns) do
      config when is_list(config) ->
        Keyword.get(config, :zone_configmap, @default_zone_configmap)

      _unset ->
        @default_zone_configmap
    end
  end
end
