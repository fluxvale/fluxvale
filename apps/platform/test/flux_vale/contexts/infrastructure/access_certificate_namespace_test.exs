defmodule FluxVale.Infrastructure.AccessCertificateNamespaceTest do
  @moduledoc false

  # Every custom-domain Certificate call resolves its namespace through
  # the ONE access-namespace resolver (`InstanceK8s.gateway_access_namespace/0`,
  # ADR-0039 §1 / #273 D2) — exactly like the gateway's own objects.
  # Pinned with a namespace that is NOT the config.exs literal: a
  # second, independently-defaulted source once answered
  # "fluxvale-access" on a production platform configured for
  # fluxvale-access-prod (#893), and prod's correctly-scoped RBAC
  # refused every certificate write.

  # NOT async: mutates the :access_gateway application env, which is
  # VM-global. Restored in on_exit.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.BillingFixtures

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

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    # The remove/verify fixtures may build a gateway; its create runs the
    # provider's provision leg.
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    # The S4 hook: a successful remove / a finished pass re-renders the
    # resolver view best-effort.
    stub(RenderAccessDNS, :call, fn -> :ok end)
    stub(RenderAccessDNS, :call, fn _opts -> :ok end)

    {org, owner} = BillingFixtures.grant_free_org!()
    BillingFixtures.mark_paid!(org)

    {:ok, org: org, owner: owner}
  end

  describe "register — the create's transaction" do
    test "applies the wildcard Certificate in the configured namespace", %{owner: owner} do
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["kind"] == "Certificate"
        assert manifest["metadata"]["namespace"] == @ns
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, _domain} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: owner
               )
    end

    test "a failed apply rolls the Certificate back in the same namespace", %{owner: owner} do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 500, body: %{"message" => "apiserver down"}}}
      end)

      expect(Kubereq, :delete, fn _req, ns, name ->
        assert ns == @ns
        assert name =~ ~r/^access-domain-[0-9a-f]{10}$/
        {:ok, %{status: 404, body: %{}}}
      end)

      assert {:error, _reason} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: owner
               )
    end
  end

  describe "the verify pass" do
    test "reads the Certificate from the configured namespace", %{owner: owner} do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, ns, name ->
        assert ns == @ns
        assert name == AccessDomain.certificate_name(domain)
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()
    end

    test "re-applies a missing Certificate into the configured namespace", %{owner: owner} do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["metadata"]["namespace"] == @ns
        assert manifest["metadata"]["name"] == AccessDomain.certificate_name(domain)
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :pending
    end
  end

  describe "remove" do
    test "safe-deletes the Certificate from the configured namespace", %{
      owner: owner
    } do
      domain = register!(owner)

      expect(Kubereq, :delete, fn _req, ns, name ->
        assert ns == @ns
        assert name == AccessDomain.certificate_name(domain)
        {:ok, %{status: 200, body: %{}}}
      end)

      assert :ok = Infrastructure.remove_access_domain(domain, actor: owner)
    end
  end

  describe "the cert replica's source read" do
    test "reads the issued wildcard Secret from the configured namespace", %{
      owner: owner
    } do
      domain = %{register!(owner) | cert_secret_ref: "access-domain-tls"}

      expect(Secret, :get_data, fn _kc, ns, name ->
        assert ns == @ns
        assert name == "access-domain-tls"
        {:ok, %{"tls.crt" => "CERT", "tls.key" => "KEY"}}
      end)

      stub(Secret, :create, fn _kc, _ns, _name, _data, _labels -> {:ok, %{}} end)

      assert {:ok, "access-domain-cert-" <> _tail} =
               EdgeRoutes.ensure_access_cert_secret(%{}, domain, "fluxvale-app-x")
    end
  end

  # --- helpers -------------------------------------------------------

  defp register!(owner) do
    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: "apps.customer.com"}, actor: owner)

    domain
  end

  defp get_row!(id), do: AccessDomain.get_by_id!(id, authorize?: false)

  defp cert_body(ready) do
    %{
      "spec" => %{"secretName" => "access-domain-tls"},
      "status" => %{"conditions" => [%{"type" => "Ready", "status" => ready}]}
    }
  end
end
