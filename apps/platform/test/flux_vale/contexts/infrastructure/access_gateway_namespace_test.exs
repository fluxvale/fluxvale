defmodule FluxVale.Infrastructure.AccessGatewayNamespaceTest do
  @moduledoc false

  # The resolver-fed access-edge writers, pinned to the CONFIGURED
  # namespace (ADR-0039 §1 / #273 D2): the gateway's credential Secret —
  # the create path's store included — and the access-dns ConfigMap.
  # Each routes through `InstanceK8s.gateway_access_namespace/0` today;
  # these pins keep it that way (a literal or a fallback reintroduced on
  # any of them goes red). The env → resolver half is pinned in
  # runtime_config_test, the certificate writers in
  # AccessCertificateNamespaceTest.

  # NOT async: mutates the :access_gateway application env, which is
  # VM-global. Restored in on_exit.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.ConfigMap
  alias FluxVale.Clients.K8s.Resources.Pod
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessProviders.Tailscale.ApiClient
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @ns "access-edge-under-test"

  setup do
    previous = Application.fetch_env(:flux_vale, :access_gateway)

    config =
      case previous do
        {:ok, value} -> value
        :error -> []
      end

    Application.put_env(:flux_vale, :access_gateway, Keyword.put(config, :namespace, @ns))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:flux_vale, :access_gateway, value)
        :error -> Application.delete_env(:flux_vale, :access_gateway)
      end
    end)

    # Both arities: the renderer resolves the platform kubeconfig (/0),
    # the provider the row-pointed one (/1).
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    InstanceFixtures.local_cluster!()

    {org, owner} = BillingFixtures.grant_free_org!()
    BillingFixtures.mark_paid!(org)
    {:ok, wallet} = FluxVale.Billing.ensure_wallet(org)
    {:ok, _grant} = FluxVale.Billing.grant_credits(wallet, 10_000, reason: :adjustment)

    {:ok, org: org, owner: owner}
  end

  describe "the gateway's credential Secret" do
    test "write_api_credential/2 targets the configured namespace", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Secret, :create, fn _kc, ns, name, data ->
        assert ns == @ns
        assert name == "api-credential-" <> short_id(gateway)
        assert data == %{"TS_API_TOKEN" => "tskey-api-new"}
        {:ok, %{}}
      end)

      assert {:ok, %{api_token_secret_ref: "api-credential-" <> _tail}} =
               Tailscale.write_api_credential(gateway, "tskey-api-new")
    end

    test "write_client_credential/3 targets the configured namespace", %{org: org} do
      gateway = AccessFixtures.gateway!(org)

      expect(Secret, :create, fn _kc, ns, name, data ->
        assert ns == @ns
        assert name == "api-credential-" <> short_id(gateway)
        assert data == %{"TS_CLIENT_ID" => "cid", "TS_CLIENT_SECRET" => "csecret"}
        {:ok, %{}}
      end)

      assert {:ok, %{api_token_secret_ref: "api-credential-" <> _tail}} =
               Tailscale.write_client_credential(gateway, "cid", "csecret")
    end

    test "the create path's store lands there too — the write a per-env platform refused",
         %{org: org, owner: owner} do
      parent = self()

      # The REAL provider writer runs (it is not stubbed); the row stops
      # at provisioning — only the store's namespace is under test.
      stub(Secret, :create, fn _kc, ns, name, data ->
        send(parent, {:secret_create, ns, name, data})
        {:ok, %{}}
      end)

      stub(Tailscale, :provision_gateway_minted, fn _gateway ->
        {:error, :provisioning_stubbed}
      end)

      stub(Tailscale, :cleanup_failed_provision, fn _gateway -> :ok end)

      assert {:error, _provisioning} =
               AccessGateway.create(
                 %{
                   organization_id: org.id,
                   monthly_cents: 200,
                   tailnet_domain: "example.ts.net",
                   api_token: "tskey-api-secret"
                 },
                 actor: owner,
                 authorize?: false
               )

      assert_received {:secret_create, @ns, "api-credential-" <> _,
                       %{"TS_API_TOKEN" => "tskey-api-secret"}}
    end
  end

  describe "the access-dns ConfigMap" do
    test "call/1 writes the Corefile into the configured namespace" do
      parent = self()

      # A stub + assert_received, never an assert inside an expect:
      # call/1 rescues everything (the derived-state stance), so an
      # assertion raised in the stub would be swallowed and the test
      # would pass on the wrong namespace.
      stub(ConfigMap, :create, fn _kc, ns, name, data ->
        send(parent, {:configmap_create, ns, name, data})
        {:ok, %{}}
      end)

      assert :ok = RenderAccessDNS.call(resolver_data: %{})

      assert_received {:configmap_create, @ns, "access-dns-zones", %{"Corefile" => _corefile}}
    end

    test "gather/0 lists a claiming gateway's pods in the configured namespace", %{
      org: org
    } do
      gateway = AccessFixtures.gateway!(org)

      claims = %{"fluxvale.lvh.me" => %{"ip" => "10.20.30.40", "tailnet" => "example.ts.net"}}

      assert {:ok, claimed} =
               AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false)

      expect(Pod, :list_by_labels, fn _kc, ns, labels ->
        assert ns == @ns
        assert labels == InstanceK8s.gateway_pod_labels(claimed.id)
        {:ok, [%{"status" => %{"phase" => "Running", "podIP" => "10.0.0.9"}}]}
      end)

      stub(Tailscale, :with_access_token, fn _gateway, fun -> fun.("tskey-api-test") end)

      stub(ApiClient, :devices_lookup, fn _token, _hostname ->
        {:ok, %{id: "dev-1", tailscale_ips: ["100.64.0.1"]}}
      end)

      claimed_id = claimed.id

      assert %{^claimed_id => %{pod_ip: "10.0.0.9", tailnet_ip: "100.64.0.1"}} =
               RenderAccessDNS.gather()
    end
  end

  defp short_id(gateway) do
    gateway.id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(-10, 10)
  end
end
