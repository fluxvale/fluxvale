defmodule FluxVale.Infrastructure.Operations.RenderAccessDNSTest do
  @moduledoc """
  The resolution plane's tests (ADR-0040 §4): golden Corefile strings
  (the fleet #122 deployment follows the rendered contract verbatim),
  the gather seam (pods + API client stubbed), and the best-effort
  write stance.
  """

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Error
  alias FluxVale.Clients.K8s.Resources.ConfigMap
  alias FluxVale.Clients.K8s.Resources.Pod
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @base_domain "fluxvale.lvh.me"
  @claims %{
    "ip" => "10.20.30.40",
    "tailnet" => "example.ts.net"
  }

  setup do
    # All three arities: the gather/write resolve the PLATFORM cluster
    # (kubeconfig/0), other helpers the row-pointed one (kubeconfig/1).
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    stub(Tailscale, :read_api_credential, fn _gateway -> {:ok, "tskey-api-test"} end)

    stub(ApiClient, :devices_lookup, fn _token, _hostname ->
      {:ok, %{id: "dev-1", tailscale_ips: ["100.64.0.1", "fd7a::1"]}}
    end)

    stub(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [running_pod("10.0.0.9")]} end)

    InstanceFixtures.local_cluster!()

    {org, owner} = BillingFixtures.grant_free_org!()

    # The instance create's funded-wallet gate (#124) — the same top-up
    # the attach tests' setup makes.
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  # ------------------------------------------------------------------
  # corefile/1 — the golden surface
  # ------------------------------------------------------------------

  describe "corefile/1" do
    test "one gateway, two domains: a view block per domain, then the default blocks" do
      views = [
        %{
          domain: @base_domain,
          view_name: "aaaaaaaaaa",
          pod_ip: "10.0.0.9",
          tailnet_ip: "100.64.0.1",
          hostnames: ["wiki.#{@base_domain}"]
        },
        %{
          domain: "terence.dev",
          view_name: "aaaaaaaaaa",
          pod_ip: "10.0.0.9",
          tailnet_ip: "100.64.0.1",
          hostnames: ["blog.terence.dev", "git.terence.dev"]
        }
      ]

      # Blocks are domain-sorted; every gateway view precedes every
      # default (first match wins). Each hosts block pins `ttl 5` (a
      # moved gateway IP converges client-side in seconds) and
      # `fallthrough` (an in-zone miss reaches the block's forward —
      # without it the hosts plugin owns the zone and misses SERVFAIL).
      assert RenderAccessDNS.corefile(views, [@base_domain, "terence.dev"]) == """
             #{@base_domain}:53 {
                 view aaaaaaaaaa {
                     expr incidr(client_ip(), "10.0.0.9/32")
                 }
                 hosts {
                     100.64.0.1 wiki.#{@base_domain}
                     ttl 5
                     fallthrough
                 }
                 forward . 1.1.1.1 8.8.8.8
             }

             terence.dev:53 {
                 view aaaaaaaaaa {
                     expr incidr(client_ip(), "10.0.0.9/32")
                 }
                 hosts {
                     100.64.0.1 blog.terence.dev
                     100.64.0.1 git.terence.dev
                     ttl 5
                     fallthrough
                 }
                 forward . 1.1.1.1 8.8.8.8
             }

             #{@base_domain}:53 {
                 forward . 1.1.1.1 8.8.8.8
             }

             terence.dev:53 {
                 forward . 1.1.1.1 8.8.8.8
             }
             """
    end

    test "two gateways, one domain: both views answer their own org's hostnames; ONE shared default" do
      views = [
        %{
          domain: @base_domain,
          view_name: "aaaaaaaaaa",
          pod_ip: "10.0.0.9",
          tailnet_ip: "100.64.0.1",
          hostnames: ["wiki.#{@base_domain}"]
        },
        %{
          domain: @base_domain,
          view_name: "bbbbbbbbbb",
          pod_ip: "10.0.0.8",
          tailnet_ip: "100.64.0.2",
          hostnames: ["forge.#{@base_domain}"]
        }
      ]

      corefile = RenderAccessDNS.corefile(views, [@base_domain])

      # The shared-tailnet one-route rule (ADR-0040 §3/§10): one
      # split-DNS route serves all gateways, so the SAME zone carries
      # BOTH views — each answering only its own org's hostname.
      assert corefile == """
             #{@base_domain}:53 {
                 view aaaaaaaaaa {
                     expr incidr(client_ip(), "10.0.0.9/32")
                 }
                 hosts {
                     100.64.0.1 wiki.#{@base_domain}
                     ttl 5
                     fallthrough
                 }
                 forward . 1.1.1.1 8.8.8.8
             }

             #{@base_domain}:53 {
                 view bbbbbbbbbb {
                     expr incidr(client_ip(), "10.0.0.8/32")
                 }
                 hosts {
                     100.64.0.2 forge.#{@base_domain}
                     ttl 5
                     fallthrough
                 }
                 forward . 1.1.1.1 8.8.8.8
             }

             #{@base_domain}:53 {
                 forward . 1.1.1.1 8.8.8.8
             }
             """
    end

    test "a view with no hostnames omits the hosts block (the nothing-attached posture)" do
      views = [
        %{
          domain: "terence.dev",
          view_name: "aaaaaaaaaa",
          pod_ip: "10.0.0.9",
          tailnet_ip: "100.64.0.1",
          hostnames: []
        }
      ]

      assert RenderAccessDNS.corefile(views, ["terence.dev"]) == """
             terence.dev:53 {
                 view aaaaaaaaaa {
                     expr incidr(client_ip(), "10.0.0.9/32")
                 }
                 forward . 1.1.1.1 8.8.8.8
             }

             terence.dev:53 {
                 forward . 1.1.1.1 8.8.8.8
             }
             """
    end

    test "no claims at all → the valid placeholder (never an unloadable Corefile)" do
      assert RenderAccessDNS.corefile([], []) == """
             # no claims
             .:53 {
                 forward . 1.1.1.1 8.8.8.8
             }
             """
    end

    test "the output is order-independent (the fleet mounts it verbatim)" do
      wiki = %{
        domain: @base_domain,
        view_name: "aaaaaaaaaa",
        pod_ip: "10.0.0.9",
        tailnet_ip: "100.64.0.1",
        hostnames: ["wiki.#{@base_domain}"]
      }

      blog = %{
        domain: "terence.dev",
        view_name: "aaaaaaaaaa",
        pod_ip: "10.0.0.9",
        tailnet_ip: "100.64.0.1",
        hostnames: ["blog.terence.dev"]
      }

      assert RenderAccessDNS.corefile([wiki, blog], [@base_domain, "terence.dev"]) ==
               RenderAccessDNS.corefile([blog, wiki], [@base_domain, "terence.dev"])
    end
  end

  # ------------------------------------------------------------------
  # render/1 — claims + resolver data from real rows
  # ------------------------------------------------------------------

  describe "render/1" do
    test "renders the org's claimed hostnames for attached private instances", %{
      org: org,
      owner: owner
    } do
      gateway = claimed_gateway!(org)
      instance = attached_private!(org, owner, gateway)

      corefile = RenderAccessDNS.render(%{gateway.id => resolver_entry()})

      assert corefile =~ ~s{expr incidr(client_ip(), "10.0.0.9/32")}
      assert corefile =~ "100.64.0.1 #{instance.slug}.#{@base_domain}"
      # Views before defaults: the view block is the FIRST occurrence of
      # the zone header, the default block the last.
      [first, last] = zone_blocks(corefile, @base_domain)
      assert first =~ "view "

      assert String.contains?(last, "forward . #{public_forwarders()}") and
               not String.contains?(last, "view ")
    end

    test "a gateway missing from the resolver data is omitted; the default block stands", %{
      org: org,
      owner: owner
    } do
      gateway = claimed_gateway!(org)
      _instance = attached_private!(org, owner, gateway)

      corefile = RenderAccessDNS.render(%{})

      refute corefile =~ "view "
      assert corefile =~ ~s{#{@base_domain}:53 {\n    forward . 1.1.1.1 8.8.8.8}
    end

    test "a PUBLIC attached instance's hostnames do not answer privately", %{
      org: org,
      owner: owner
    } do
      gateway = claimed_gateway!(org)
      instance = attached_public!(org, owner, gateway)

      corefile = RenderAccessDNS.render(%{gateway.id => resolver_entry()})

      refute corefile =~ instance.slug
      assert corefile =~ "forward ."
    end

    test "a SUSPENDED domain keeps its claim but answers nothing (the ladder's demotion)", %{
      org: org,
      owner: owner
    } do
      gateway = claimed_gateway!(org)
      instance = attached_private!(org, owner, gateway)

      # mark_suspended is the billing ladder's funnel (S6's writer; the
      # ladder itself is a later slice).
      domain = domain_row!(org, @base_domain)
      {:ok, _suspended} = AccessDomain.mark_suspended(domain, %{}, authorize?: false)

      corefile = RenderAccessDNS.render(%{gateway.id => resolver_entry()})

      refute corefile =~ instance.slug
      # The claim's zone still gets its default (public-recursion) block.
      assert corefile =~ @base_domain
    end

    test "a claim whose domain ROW is gone answers nothing — and the default still stands", %{
      org: org
    } do
      # The claims map outlived its row (a remove that lost the claims
      # write): the answerable-domain lookup misses, the view is skipped,
      # and the zone keeps its public-recursion fallback.
      gateway = claimed_gateway!(org)

      corefile = RenderAccessDNS.render(%{gateway.id => resolver_entry()})

      refute corefile =~ "view "
      assert corefile =~ ~s{#{@base_domain}:53 {\n    forward . 1.1.1.1 8.8.8.8}
    end
  end

  # ------------------------------------------------------------------
  # gather/0 — the pods + API seam
  # ------------------------------------------------------------------

  describe "gather/0" do
    test "collects pod and tailnet IPs per claiming gateway", %{org: org} do
      gateway = claimed_gateway!(org)

      expect(Pod, :list_by_labels, fn _kc, ns, labels ->
        assert ns == "fluxvale-access"

        assert labels == %{
                 "app.kubernetes.io/name" => "access-gateway",
                 "fluxvale.io/gateway" => gateway.id
               }

        {:ok, [pending_pod(), running_pod("10.0.0.9")]}
      end)

      expect(ApiClient, :devices_lookup, fn _token, hostname ->
        assert hostname == gateway.hostname
        {:ok, %{id: "dev-1", tailscale_ips: ["fd7a::1", "100.64.0.1"]}}
      end)

      assert RenderAccessDNS.gather() == %{
               gateway.id => %{pod_ip: "10.0.0.9", tailnet_ip: "100.64.0.1"}
             }
    end

    test "a gateway with no RUNNING pod is omitted (the between-restarts window)", %{org: org} do
      gateway = claimed_gateway!(org)

      stub(Pod, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [pending_pod()]} end)

      assert RenderAccessDNS.gather() == %{}
    end

    test "a gateway whose device lookup fails is omitted", %{org: org} do
      gateway = claimed_gateway!(org)

      stub(ApiClient, :devices_lookup, fn _token, _hostname -> {:error, :unauthorized} end)

      assert RenderAccessDNS.gather() == %{}
    end

    test "a v6-only node is omitted — an A record needs a real IPv4", %{org: org} do
      gateway = claimed_gateway!(org)

      stub(ApiClient, :devices_lookup, fn _token, _hostname ->
        {:ok, %{id: "dev-1", tailscale_ips: ["fd7a::1", "fd7a::2"]}}
      end)

      assert RenderAccessDNS.gather() == %{}
    end

    test "a malformed address payload is omitted — validated, never sniffed", %{org: org} do
      gateway = claimed_gateway!(org)

      stub(ApiClient, :devices_lookup, fn _token, _hostname ->
        {:ok, %{id: "dev-1", tailscale_ips: ["not-an-ip", "999.1.2.3", "10.0.0.x"]}}
      end)

      assert RenderAccessDNS.gather() == %{}
    end

    test "pod selection: terminating pods excluded, the NEWEST survivor wins", %{org: org} do
      gateway = claimed_gateway!(org)

      expect(Pod, :list_by_labels, fn _kc, _ns, _labels ->
        {:ok,
         [
           pod("10.0.0.1", "2026-11-01T01:00:00Z"),
           terminating_pod("10.0.0.2", "2026-11-01T03:00:00Z"),
           pod("10.0.0.9", "2026-11-01T02:00:00Z")
         ]}
      end)

      # The newest survivor (02:00) wins; the newer-but-terminating pod
      # (03:00) is a reuse window, never a source.
      assert RenderAccessDNS.gather() == %{
               gateway.id => %{pod_ip: "10.0.0.9", tailnet_ip: "100.64.0.1"}
             }
    end

    test "a gateway with only TERMINATING pods takes the no-pod omission path", %{org: org} do
      claimed_gateway!(org)

      stub(Pod, :list_by_labels, fn _kc, _ns, _labels ->
        {:ok, [terminating_pod("10.0.0.2", "2026-11-01T03:00:00Z")]}
      end)

      assert RenderAccessDNS.gather() == %{}
    end

    test "a gateway with no readable API token is omitted", %{org: org} do
      claimed_gateway!(org)

      stub(Tailscale, :read_api_credential, fn _gateway -> {:error, :no_api_token} end)

      assert RenderAccessDNS.gather() == %{}
    end

    test "no claiming gateways → no cluster calls at all" do
      reject(K8s, :kubeconfig, 0)

      assert RenderAccessDNS.gather() == %{}
    end
  end

  # ------------------------------------------------------------------
  # call/1 — the one cluster write, best-effort
  # ------------------------------------------------------------------

  describe "call/1" do
    test "writes the whole Corefile under one key to the default ConfigMap", %{
      org: org,
      owner: owner
    } do
      gateway = claimed_gateway!(org)
      instance = attached_private!(org, owner, gateway)

      expect(ConfigMap, :create, fn _kc, ns, name, data ->
        assert ns == "fluxvale-access"
        assert name == "access-dns-zones"
        assert %{"Corefile" => corefile} = data
        assert corefile =~ "view "
        assert corefile =~ "#{instance.slug}.#{@base_domain}"
        assert gateway.id
        {:ok, %{}}
      end)

      assert RenderAccessDNS.call() == :ok
    end

    test "honors the :zone_configmap config override", %{org: org} do
      claimed_gateway!(org)

      previous = Application.get_env(:flux_vale, :access_dns)

      Application.put_env(:flux_vale, :access_dns,
        resolver_ip: "10.20.30.40",
        zone_configmap: "custom-zones"
      )

      on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

      expect(ConfigMap, :create, fn _kc, _ns, "custom-zones", _data -> {:ok, %{}} end)

      assert RenderAccessDNS.call() == :ok
    end

    test "a ConfigMap write failure is logged, never raised (the derived-state stance)", %{
      org: org
    } do
      claimed_gateway!(org)

      stub(ConfigMap, :create, fn _kc, _ns, _name, _data ->
        {:error, Error.api_error("boom")}
      end)

      assert RenderAccessDNS.call() == :ok
    end

    test "a crash inside the pass is contained (:ok) — a flip must never fail on it", %{org: org} do
      claimed_gateway!(org)

      stub(Pod, :list_by_labels, fn _kc, _ns, _labels -> raise "cluster exploded" end)

      assert RenderAccessDNS.call() == :ok
    end

    test "a precomputed resolver_data skips the gather", %{org: org, owner: owner} do
      gateway = claimed_gateway!(org)
      _instance = attached_private!(org, owner, gateway)

      reject(Pod, :list_by_labels, 3)
      reject(ApiClient, :devices_lookup, 2)

      expect(ConfigMap, :create, fn _kc, _ns, _name, %{"Corefile" => corefile} ->
        assert corefile =~ "100.64.0.1"
        {:ok, %{}}
      end)

      assert RenderAccessDNS.call(resolver_data: %{gateway.id => resolver_entry()}) == :ok
    end

    test "zero claims write the PLACEHOLDER (a valid reloadable Corefile, never empty)" do
      expect(ConfigMap, :create, fn _kc, _ns, _name, %{"Corefile" => corefile} ->
        assert corefile == """
               # no claims
               .:53 {
                   forward . 1.1.1.1 8.8.8.8
               }
               """

        {:ok, %{}}
      end)

      assert RenderAccessDNS.call() == :ok
    end
  end

  # ------------------------------------------------------------------
  # Fixtures
  # ------------------------------------------------------------------

  defp resolver_entry, do: %{pod_ip: "10.0.0.9", tailnet_ip: "100.64.0.1"}
  defp public_forwarders, do: "1.1.1.1 8.8.8.8"

  # The Corefile's blocks for one zone, in file order: "<zone>:53 {" up
  # to the closing "}".
  defp zone_blocks(corefile, zone) do
    corefile
    |> String.split("\n\n")
    |> Enum.filter(&String.starts_with?(&1, "#{zone}:53 {"))
  end

  defp running_pod(ip) do
    %{"status" => %{"phase" => "Running", "podIP" => ip}}
  end

  # A live pod with a creation stamp (the newest-survivor ordering key).
  defp pod(ip, created_at) do
    %{
      "metadata" => %{"creationTimestamp" => created_at},
      "status" => %{"phase" => "Running", "podIP" => ip}
    }
  end

  defp terminating_pod(ip, created_at) do
    pod = pod(ip, created_at)
    put_in(pod, ["metadata", "deletionTimestamp"], "2026-11-01T03:30:00Z")
  end

  defp pending_pod do
    %{"status" => %{"phase" => "Pending"}}
  end

  # A gateway row with a live claim on the test base domain (through the
  # system funnel — the claims-write path production uses).
  defp claimed_gateway!(org) do
    gateway = AccessFixtures.gateway!(org)

    {:ok, claimed} =
      AccessGateway.update_claims(gateway, %{dns_claims: %{@base_domain => @claims}},
        authorize?: false
      )

    claimed
  end

  # A deployed private instance attached to the gateway, with its
  # default hostname minted (the create action's MintDefaultHostname).
  defp attached_private!(org, owner, gateway) do
    instance = AccessFixtures.private_instance!(org, owner)

    {:ok, _route} =
      AccessRoute.create(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

    instance
  end

  # Same pairing, but the row is public: the view must not answer it.
  defp attached_public!(org, owner, gateway) do
    instance = AccessFixtures.public_instance!(org, owner)

    {:ok, _route} =
      AccessRoute.create(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

    instance
  end

  defp domain_row!(org, name) do
    AccessDomain
    |> Ash.Query.filter(organization_id == ^org.id and domain == ^name)
    |> Ash.read_one!(authorize?: false)
  end
end
