defmodule FluxVale.Infrastructure.Operations.VerifyAccessDomainsTest do
  @moduledoc false

  # ADR-0040 S1's verify-by-issuance ladder: the observer pass is the
  # ONLY promoter to :verified (issuance success IS the verification),
  # the deadline fails a stalled :pending, and observed states self-heal
  # (:verified ⇄ :needs_attention) — the gateway-observer stance.

  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Ingress
  alias FluxVale.Clients.K8s.Resources.Middleware
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Clients.K8s.Resources.Service
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @deadline_hours 72

  setup do
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    # The public drift sweep's cluster read: no routes by default; the
    # drift tests override with their standing-route bodies.
    stub(Ingress, :list_by_labels, fn _kc, _ns, _labels -> {:ok, []} end)

    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    # The promotion claim's provider limb: no token in these fixtures, so
    # the sweep stands down (the claim suites stub the success arm).
    stub(Tailscale, :claim_domain, fn _gw, _name, _ip -> {:error, :no_api_token} end)

    previous = Application.get_env(:flux_vale, :access_dns)
    Application.put_env(:flux_vale, :access_dns, resolver_ip: "10.43.0.20")
    on_exit(fn -> Application.put_env(:flux_vale, :access_dns, previous) end)

    # The S4 hook: the pass ends with the resolver-view re-render
    # (best-effort). Default success; expect-ed where a test cares.
    stub(FluxVale.Infrastructure.Operations.RenderAccessDNS, :call, fn -> :ok end)
    stub(FluxVale.Infrastructure.Operations.RenderAccessDNS, :call, fn _opts -> :ok end)
    AccessFixtures.stub_gateway_pod()

    {org, owner} = BillingFixtures.grant_free_org!()
    BillingFixtures.mark_paid!(org)

    {:ok, org: org, owner: owner}
  end

  describe ":pending rows" do
    test "Ready=True promotes to :verified and records cert_secret_ref — and only then", %{
      owner: owner
    } do
      domain = register!(owner)

      # The core promise: registration alone proves nothing.
      assert domain.state == :pending
      assert domain.cert_secret_ref == nil

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      row = get_row!(domain.id)
      assert row.state == :verified
      assert row.cert_secret_ref == "access-domain-tls"
    end

    test "promotion claims the domain it verified", %{org: org, owner: owner} do
      gateway = AccessFixtures.gateway!(org)
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      stub(Tailscale, :claim_domain, fn gw, name, resolver_ip ->
        assert gw.id == gateway.id
        assert name == "apps.customer.com"
        assert resolver_ip == "10.43.0.20"
        {:ok, %{device_id: "device-1", route: "10.43.0.20/32"}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()

      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims[domain.domain]["ip"] == "10.43.0.20"
    end

    test "a promotion with no gateway stays verified and claims nothing", %{owner: owner} do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:error, _no_gateway} =
               AccessGateway.get_for_organization(domain.organization_id, authorize?: false)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
    end

    test "Ready != True inside the window leaves the row :pending", %{owner: owner} do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :pending
    end

    test "past the deadline without Ready -> :failed", %{org: org} do
      # The aged :pending row is a state actions cannot produce (the
      # create stamps `registered_at` with now) — the Ash.seed! case.
      domain =
        Ash.Seed.seed!(AccessDomain, %{
          organization_id: org.id,
          domain: "late.example.com",
          kind: :custom,
          state: :pending,
          registered_at: hours_ago(@deadline_hours + 1)
        })

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{failed: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :failed
    end

    test "a missing Certificate inside the window is re-applied — the row stays :pending", %{
      owner: owner
    } do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      # The reconcile limb: same name, same spec shape.
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["spec"]["dnsNames"] == ["*.apps.customer.com"]
        assert manifest["spec"]["secretName"] == AccessDomain.certificate_name(domain)
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :pending
    end

    test "a missing Certificate past the deadline is NOT re-applied — the window is closed", %{
      org: org
    } do
      Ash.Seed.seed!(AccessDomain, %{
        organization_id: org.id,
        domain: "vanished.example.com",
        kind: :custom,
        state: :pending,
        registered_at: hours_ago(@deadline_hours + 1)
      })

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      stub(Kubereq, :apply, fn _req, _manifest, _fm ->
        flunk("no re-apply expected past the deadline")
      end)

      assert {:ok, %{failed: 1}} = Infrastructure.verify_access_domains()
    end

    test "a transient cluster read failure touches nothing", %{owner: owner} do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:error, :transport_oops}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :pending
    end
  end

  describe "self-healing (:verified ⇄ :needs_attention)" do
    test ":verified with Ready=False lands :needs_attention, Ready=True returns it", %{
      owner: owner
    } do
      domain = register!(owner)
      promote_to_verified!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{needs_attention: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :needs_attention

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()

      row = get_row!(domain.id)
      assert row.state == :verified
      assert row.cert_secret_ref == "access-domain-tls"
    end

    test "cert loss self-heals: :verified + 404 re-applies the Certificate, demotes, and recovers",
         %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      # The reconcile limb: same name, same spec shape.
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["spec"]["dnsNames"] == ["*.apps.customer.com"]
        assert manifest["spec"]["secretName"] == AccessDomain.certificate_name(domain)
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, %{needs_attention: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :needs_attention

      # The re-applied Certificate comes Ready — the row recovers.
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
    end

    test ":needs_attention whose Certificate is missing gets re-applied and stays put", %{
      owner: owner
    } do
      domain = register!(owner)
      promote_to_verified!(domain)
      demote!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 201, body: %{}}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :needs_attention
    end

    test "a reconcile re-apply that fails is logged and left for the next tick", %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:error, :transport_oops}
      end)

      assert {:ok, %{needs_attention: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :needs_attention
    end

    test ":verified with Ready absent (reconciling) does not flap", %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: %{"kind" => "Certificate"}}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :verified
    end

    test ":verified under a transient read failure stands (no flap on a flaky read)", %{
      owner: owner
    } do
      domain = register!(owner)
      promote_to_verified!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:error, :transport_oops}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :verified
    end

    test ":needs_attention under a transient read failure stands", %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)
      demote!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:error, :transport_oops}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :needs_attention
    end

    test "Ready=True with no secretName is treated as not-ready — no promotion", %{owner: owner} do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok,
         %{
           status: 200,
           body: %{"status" => %{"conditions" => [%{"type" => "Ready", "status" => "True"}]}}
         }}
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()

      row = get_row!(domain.id)
      assert row.state == :pending
      assert row.cert_secret_ref == nil
    end
  end

  describe "stale-write guards" do
    test "a row whose state moved mid-pass is skipped — no stale demotion", %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      # Another writer moves the row between the pass's read and the
      # land: the fresh re-read inside the funnel sees a different state
      # and must skip (stubbed at the code-interface seam).
      moved = %{get_row!(domain.id) | state: :suspended}
      stub(AccessDomain, :get_by_id, fn _id, _opts -> {:ok, moved} end)

      stub(AccessDomain, :mark_needs_attention, fn _domain, _params, _opts ->
        flunk("a moved row must not be written")
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :verified
    end

    test "a row removed mid-pass is skipped — nothing to write", %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      stub(AccessDomain, :get_by_id, fn _id, _opts -> {:error, :gone} end)

      stub(AccessDomain, :mark_needs_attention, fn _domain, _params, _opts ->
        flunk("a removed row must not be written")
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()
    end

    test "a failed transition write surfaces {:error, {:land_failed, n}} — Oban retries", %{
      owner: owner
    } do
      domain = register!(owner)
      promote_to_verified!(domain)

      stub(AccessDomain, :mark_needs_attention, fn _domain, _params, _opts ->
        {:error, :forced_failure}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:error, {:land_failed, 1}} = Infrastructure.verify_access_domains()
    end
  end

  describe "out-of-scope rows" do
    test ":platform rows and :failed rows are left alone", %{org: org, owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      # authorize?: false — system-precondition rows (the platform shape
      # the instance path mints; a terminal registration).
      AccessDomain.mint_platform(
        %{
          domain: Application.fetch_env!(:flux_vale, :instances_base_domain),
          organization_id: org.id
        },
        authorize?: false
      )

      Ash.Seed.seed!(AccessDomain, %{
        organization_id: org.id,
        domain: "dead.example.com",
        kind: :custom,
        state: :failed,
        registered_at: hours_ago(1)
      })

      # The pass's only legitimate cluster read is the :verified row's
      # (platform rows are filtered at the query, :failed is terminal) —
      # the single expectation catches any read beyond it.
      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()
    end

    test "an unreachable platform cluster errors the pass" do
      stub(K8s, :kubeconfig, fn ->
        {:error, "No in-cluster kubeconfig (service-account files missing?)"}
      end)

      assert {:error, _reason} = Infrastructure.verify_access_domains()
    end
  end

  describe "the S6 suspension funnel" do
    test "mark_suspended demotes a serving row; a never-served row is left alone", %{
      owner: owner
    } do
      pending = register!(owner)

      # A :pending row never served — the funnel's guard leaves it
      # alone (the ladder selects serving rows only; the guard is the
      # backstop). Same for :failed — there is nothing to demote.
      assert {:ok, untouched} = AccessDomain.mark_suspended(pending, authorize?: false)
      assert untouched.state == :pending

      # A verified row demotes through the funnel — and its cluster
      # legs are no-ops on a domain with no hostnames and no gateway.
      verified =
        Ash.update!(pending, %{cert_secret_ref: "cert-secret"},
          action: :mark_verified,
          authorize?: false
        )

      assert {:ok, suspended} = AccessDomain.mark_suspended(verified, authorize?: false)
      assert suspended.state == :suspended
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # ----------------------------------------------------------------
  # ADR-0040 Am. 1 as built: the arms follow the domain, and the cert
  # replica syncs on the pass's cadence.
  # ----------------------------------------------------------------
  describe "the arms follow the domain (ADR-0040 Am. 1)" do
    test "promotion mints the arms for the domain's attached private instances", %{
      org: org,
      owner: owner
    } do
      domain = register!(owner)
      {instance, _gateway} = attached_hostname!(org, owner, domain)

      stub_arm_creates(instance.namespace)
      stub_cert_replica()

      expect(Ingress, :create, 2, fn _kc, ns, "access-" <> _tail, spec ->
        assert ns == instance.namespace

        case spec.host do
          "wiki.apps.customer.com" ->
            # The custom domain's route references the LOCAL replica name.
            assert spec.tls_secret_name =~ ~r/^access-domain-cert-[0-9a-f]{10}$/

          _platform_hostname ->
            # The platform domain rides the default TLSStore — no secret.
            refute Map.has_key?(spec, :tls_secret_name)
        end

        {:ok, %{}}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
    end

    test "an arm-mint failure on promotion logs and still lands the promotion", %{
      org: org,
      owner: owner
    } do
      domain = register!(owner)
      {instance, _gateway} = attached_hostname!(org, owner, domain)

      stub_arm_creates(instance.namespace)
      stub_cert_replica()

      stub(Ingress, :create, fn _kc, _ns, _name, _spec ->
        {:error, :routes_refused}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
    end

    test ":failed demotes nothing — a failed domain never routed", %{org: org, owner: owner} do
      # The aged :pending row is a state actions cannot produce — the
      # Ash.seed! case.
      domain =
        Ash.Seed.seed!(AccessDomain, %{
          organization_id: org.id,
          domain: "late.example.com",
          kind: :custom,
          state: :pending,
          registered_at: hours_ago(@deadline_hours + 1)
        })

      {_instance, _gateway} = attached_hostname!(org, owner, domain)

      # The instance's OTHER hostnames keep serving: a failed domain
      # never had routes of its own (unverified rows are skipped at
      # mint), so the failure removes nothing.
      reject(Ingress, :delete, 3)
      reject(Middleware, :delete, 3)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{failed: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :failed
    end

    test ":needs_attention keeps serving — no arm removal on the healing state", %{
      org: org,
      owner: owner
    } do
      # A :verified row is a state the pass alone produces — seed it the
      # way a past pass left it.
      domain =
        Ash.Seed.seed!(AccessDomain, %{
          organization_id: org.id,
          domain: "wobbly.example.com",
          kind: :custom,
          state: :verified,
          cert_secret_ref: "access-domain-tls",
          registered_at: hours_ago(1)
        })

      {_instance, _gateway} = attached_hostname!(org, owner, domain)

      stub_arm_deletes(org)

      # The cert replica still syncs on the pass (the cert is still
      # valid and the arms keep serving through it).
      stub(Secret, :get_data, fn _kc, "fluxvale-access", "access-domain-tls" ->
        {:ok, %{"tls.crt" => "CERT", "tls.key" => "KEY"}}
      end)

      stub(Secret, :create, fn _kc, _ns, "access-domain-cert-" <> _tail, _data, _labels ->
        {:ok, %{}}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{needs_attention: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :needs_attention

      # The cert is still valid and the reconcile limb is healing: the
      # arms must still be standing.
      refute_received {:access_route_removed}
      refute_received {:access_middleware_removed}
    end

    test "the sync limb re-ensures each :verified domain's cert replica per serving namespace", %{
      org: org,
      owner: owner
    } do
      domain =
        Ash.Seed.seed!(AccessDomain, %{
          organization_id: org.id,
          domain: "steady.example.com",
          kind: :custom,
          state: :verified,
          cert_secret_ref: "access-domain-tls",
          registered_at: hours_ago(1)
        })

      {instance, _gateway} = attached_hostname!(org, owner, domain)

      # Non-serving instances with hostnames under the domain are
      # skipped by the sync's join: an UNATTACHED private row holds no
      # access arms. (A public row is a serving row since the
      # public-custom lane — its namespace syncs too, pinned by the
      # public-plane describe below — so exactly TWO namespaces.)
      unattached = AccessFixtures.private_instance!(org, owner)

      InstanceHostname.mint!(
        %{instance_id: unattached.id, access_domain_id: domain.id, label: "dark"},
        authorize?: false
      )

      public = AccessFixtures.public_instance!(org, owner)

      InstanceHostname.mint!(
        %{instance_id: public.id, access_domain_id: domain.id, label: "also-dark"},
        authorize?: false
      )

      stub_arm_creates(instance.namespace)

      expect(Secret, :get_data, 2, fn _kc, "fluxvale-access", "access-domain-tls" ->
        {:ok, %{"tls.crt" => "CERT", "tls.key" => "KEY"}}
      end)

      # The replica apply FAILS: the sync logs it and moves on — the
      # next tick converges (SSA).
      stub(Secret, :create, fn _kc, _ns, "access-domain-cert-" <> _tail, _data, _labels ->
        {:error, :replica_refused}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      # Unchanged observation — the SYNC is the work this pass does.
      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()
    end
  end

  defp register!(owner) do
    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: "apps.customer.com"}, actor: owner)

    domain
  end

  defp promote_to_verified!(domain) do
    expect(Kubereq, :get, fn _req, _ns, _name ->
      {:ok, %{status: 200, body: cert_body("True")}}
    end)

    assert {:ok, _counts} = Infrastructure.verify_access_domains()
    assert get_row!(domain.id).state == :verified
  end

  defp demote!(domain) do
    expect(Kubereq, :get, fn _req, _ns, _name ->
      {:ok, %{status: 200, body: cert_body("False")}}
    end)

    assert {:ok, _counts} = Infrastructure.verify_access_domains()
    assert get_row!(domain.id).state == :needs_attention
  end

  defp get_row!(id) do
    AccessDomain.get_by_id!(id, authorize?: false)
  end

  defp cert_body(ready) do
    %{
      "spec" => %{"secretName" => "access-domain-tls"},
      "status" => %{"conditions" => [%{"type" => "Ready", "status" => ready}]}
    }
  end

  defp hours_ago(hours) do
    DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
  end

  # Exactly one cluster row per test — ResolveCluster refuses multiple
  # (ADR-0006), so helpers that both build instances share this.
  defp single_cluster! do
    clusters =
      Cluster
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case clusters do
      [] -> InstanceFixtures.local_cluster!()
      [cluster] -> cluster
    end
  end

  # The attached-private-instance shape the arms serve, with a hostname
  # row under `domain` (the row is created directly — attach itself is
  # the operation tests' subject).
  defp attached_hostname!(org, owner, domain) do
    single_cluster!()

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    # Instance create's funded-wallet gate (#124).
    {_org, _wallet} = BillingFixtures.funded_wallet!(org: org)

    # The gateway create runs the provider's provision leg.
    stub(Tailscale, :provision_gateway, fn _gateway, _key ->
      {:ok, %{credential_secret_ref: "credential-stub"}}
    end)

    gateway = AccessFixtures.gateway!(org)
    instance = AccessFixtures.private_instance!(org, owner)

    # The hostname row under THIS domain (the default slug row rides the
    # org's platform domain).
    InstanceHostname.mint!(
      %{instance_id: instance.id, access_domain_id: domain.id, label: "wiki"},
      authorize?: false
    )

    {:ok, _route} =
      AccessRoute.create(
        %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
        authorize?: false
      )

    {instance, gateway}
  end

  defp stub_arm_creates(ns) do
    stub(Service, :create, fn _kc, ^ns, _name, _spec -> {:ok, %{}} end)
    stub(Middleware, :create, fn _kc, ^ns, _name, _spec -> {:ok, %{}} end)

    stub(Ingress, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
  end

  defp stub_arm_deletes(_org) do
    parent = self()

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Ingress, :delete, fn _kc, _ns, "access-" <> _tail ->
      send(parent, {:access_route_removed})
      :ok
    end)

    stub(Middleware, :delete, fn _kc, _ns, "fluxvale-access-wake" ->
      send(parent, {:access_middleware_removed})
      :ok
    end)
  end

  defp stub_cert_replica do
    stub(Secret, :get_data, fn _kc, "fluxvale-access", "access-domain-tls" ->
      {:ok, %{"tls.crt" => "CERT", "tls.key" => "KEY"}}
    end)

    stub(Secret, :create, fn _kc, _ns, "access-domain-cert-" <> _tail, _data, _labels ->
      {:ok, %{}}
    end)
  end

  # A :verified row is a state the pass alone produces — seed it the
  # way a past pass left it (the sync-limb test's shape).
  defp seed_verified_domain(org, name) do
    Ash.Seed.seed!(AccessDomain, %{
      organization_id: org.id,
      domain: name,
      kind: :custom,
      state: :verified,
      cert_secret_ref: "access-domain-tls",
      registered_at: hours_ago(1)
    })
  end

  # The public-instance shape the public arms serve, with a hostname
  # row under `domain` — no pairing, no gateway (the public predicate:
  # the exposure IS the delivery path).
  defp public_hostname!(org, owner, domain) do
    single_cluster!()

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    # Instance create's funded-wallet gate (#124).
    {_org, _wallet} = BillingFixtures.funded_wallet!(org: org)

    instance = AccessFixtures.public_instance!(org, owner)
    row = AccessFixtures.mint_hostname!(instance, domain, "sso")

    {instance, row}
  end

  # A public instance that never deployed: no namespace pinned (the
  # pre-deploy shape — the row can exist before the namespace does).
  defp undeployed_public_instance!(org, owner) do
    single_cluster!()

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    # Instance create's funded-wallet gate (#124).
    {_org, _wallet} = BillingFixtures.funded_wallet!(org: org)

    version = InstanceFixtures.app_version!()

    Instance.create!(
      %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
      actor: owner
    )
  end

  defp hostname_rows(domain_id) do
    InstanceHostname
    |> Ash.Query.filter(access_domain_id == ^domain_id)
    |> Ash.read!(authorize?: false)
  end

  # EdgeRoutes' object_name short_id derivation — the sweep recognizes
  # routes by the same names the mint stamps.
  defp route_tail(id) do
    id
    |> to_string()
    |> String.replace("-", "")
    |> String.slice(-10, 10)
  end

  defp custom_name_for(row), do: "custom-" <> route_tail(row.id)
  defp access_name_for(row), do: "access-" <> route_tail(row.id)

  # A LISTED IngressRoute body, shaped the way the cluster returns it.
  defp route_body(namespace, name, domain_id) do
    %{
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{"fluxvale.io/access-domain" => domain_id}
      }
    }
  end

  defp drain_routes(acc) do
    receive do
      {:route_created, ns, name, spec} -> drain_routes([{ns, name, spec} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "the S4 render hook (ADR-0040 §4)" do
    test "the pass ends with the resolver-view re-render — the pod-move refresher", %{
      owner: owner
    } do
      # A :pending domain inside the window: the pass reads its
      # Certificate, lands nothing, and STILL ends with the render.
      register!(owner)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()
    end
  end

  describe "the URL-env sync rides the arm-mint pass (ADR-0052)" do
    test "promotion syncs each serving instance — one enumeration, no second pass", %{
      org: org,
      owner: owner
    } do
      domain = register!(owner)
      {instance, _gateway} = attached_hostname!(org, owner, domain)

      stub_arm_creates(instance.namespace)
      stub_cert_replica()

      # The SAME pass that mints the arms re-tells the instance — the
      # promotion's population, nothing more.
      expect(SyncInstanceUrlEnv, :call, fn synced ->
        assert synced.id == instance.id
        :ok
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
    end

    test "a sync failure is warn-only — the promotion still lands", %{org: org, owner: owner} do
      domain = register!(owner)
      {instance, _gateway} = attached_hostname!(org, owner, domain)

      stub_arm_creates(instance.namespace)
      stub_cert_replica()
      stub(SyncInstanceUrlEnv, :call, fn _instance -> {:error, :boom} end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
    end
  end

  # ------------------------------------------------------------------
  # The public plane follows the domain (the public-custom lane): the
  # selector serves BOTH planes, promotion mints both, and the drift
  # sweep walks the ACTUAL routes — the only sweep that can remove a
  # row-less orphan.
  # ------------------------------------------------------------------
  describe "the public plane follows the domain" do
    test "promotion mints the public arms for the domain's public instances", %{
      org: org,
      owner: owner
    } do
      domain = register!(owner)
      {instance, _row} = public_hostname!(org, owner, domain)

      stub(EdgeRoutes, :apply_public_for_status, fn _kc, sent_instance ->
        assert sent_instance.id == instance.id
        send(self(), {:public_armed, sent_instance.id})
        :ok
      end)

      # The SAME pass re-tells the instance its URL env.
      expect(SyncInstanceUrlEnv, :call, fn synced ->
        assert synced.id == instance.id
        :ok
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
      assert_received {:public_armed, _instance_id}
    end

    test "a public arm-mint failure is warn-only — the promotion still lands", %{
      org: org,
      owner: owner
    } do
      domain = register!(owner)
      {_instance, _row} = public_hostname!(org, owner, domain)

      stub(EdgeRoutes, :apply_public_for_status, fn _kc, _sent ->
        {:error, :cluster_refused}
      end)

      stub(SyncInstanceUrlEnv, :call, fn _instance -> :ok end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :verified
    end

    test "the pass deletes a stale public route on a private instance", %{org: org, owner: owner} do
      domain = seed_verified_domain(org, "stale.example.com")
      {instance, _gateway} = attached_hostname!(org, owner, domain)

      row =
        domain.id
        |> hostname_rows()
        |> List.first()

      stale_name = custom_name_for(row)

      stub(Ingress, :list_by_labels, fn _kc, _ns, _labels ->
        {:ok,
         [
           route_body(instance.namespace, stale_name, domain.id),
           route_body(instance.namespace, "app-ingress", domain.id)
         ]}
      end)

      stub(Ingress, :delete, fn _kc, ns, name ->
        send(self(), {:stale_removed, ns, name})
        :ok
      end)

      stub_cert_replica()

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()

      # The route's row is live but its instance went PRIVATE: no
      # justification, it comes down. The access family's route
      # (app-ingress is not even custom-named) is untouched.
      assert_received {:stale_removed, namespace, ^stale_name}
      assert namespace == instance.namespace
      refute_received {:stale_removed, _ns, "app-ingress"}
    end

    test "the pass sweeps an orphaned custom route with no row", %{org: org, owner: owner} do
      domain = seed_verified_domain(org, "orphan.example.com")
      {instance, row} = public_hostname!(org, owner, domain)

      # Stage the standing route the honest way: the row named it, the
      # mint happened, the row was destroyed (a pre-wiring remove) —
      # the route stub stays live with nobody to name it.
      orphan_name = custom_name_for(row)
      namespace = instance.namespace
      Ash.destroy!(row, action: :destroy, authorize?: false)

      stub(Ingress, :list_by_labels, fn _kc, _ns, _labels ->
        {:ok, [route_body(namespace, orphan_name, domain.id)]}
      end)

      stub(Ingress, :delete, fn _kc, sent_ns, sent_name ->
        send(self(), {:stale_removed, sent_ns, sent_name})
        :ok
      end)

      stub_cert_replica()

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()

      # The row-keyed walks can never name this route; the ROUTE-keyed
      # sweep is the only sweeper that can.
      assert_received {:stale_removed, ^namespace, ^orphan_name}
    end

    test "the pass re-applies a public instance's arms idempotently", %{org: org, owner: owner} do
      domain = seed_verified_domain(org, "converge.example.com")
      {instance, row} = public_hostname!(org, owner, domain)
      justified = route_body(instance.namespace, custom_name_for(row), domain.id)

      stub(Ingress, :list_by_labels, fn _kc, _ns, _labels -> {:ok, [justified]} end)

      stub(Ingress, :delete, fn _kc, _ns, _name ->
        flunk("a justified route is re-applied, not deleted")
      end)

      stub_cert_replica()

      stub(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      stub(EdgeRoutes, :apply_public_for_status, fn _kc, sent_instance ->
        send(self(), {:reapplied, sent_instance.id})
        :ok
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()
      assert_received {:reapplied, instance_id}
      assert instance_id == instance.id

      # A failed re-apply never fails the pass — the next tick converges.
      stub(EdgeRoutes, :apply_public_for_status, fn _kc, _sent ->
        send(self(), {:reapplied, :failed})
        {:error, :cluster_refused}
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()
      assert_received {:reapplied, :failed}
    end

    test "the replica sync covers a public instance's namespace", %{org: org, owner: owner} do
      domain = seed_verified_domain(org, "steady-public.example.com")
      {instance, _row} = public_hostname!(org, owner, domain)

      expect(Secret, :get_data, fn _kc, "fluxvale-access", "access-domain-tls" ->
        {:ok, %{"tls.crt" => "CERT", "tls.key" => "KEY"}}
      end)

      expect(Secret, :create, fn _kc, ns, "access-domain-cert-" <> _tail, _data, _labels ->
        assert ns == instance.namespace
        {:ok, %{}}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()
    end

    test "the replica sync skips an undeployed public instance", %{org: org, owner: owner} do
      domain = seed_verified_domain(org, "undeployed.example.com")
      {deployed, _row} = public_hostname!(org, owner, domain)

      # The undeployed sibling: a public instance with a hostname row
      # but no namespace pinned (the system mint needs no deployment) —
      # nothing to replicate into.
      undeployed = undeployed_public_instance!(org, owner)
      AccessFixtures.mint_hostname!(undeployed, domain, "early")

      # Exactly ONE replica flow — the deployed sibling's. A second
      # Secret call (the nil-namespace warn shape) fails the test.
      expect(Secret, :get_data, 1, fn _kc, "fluxvale-access", "access-domain-tls" ->
        {:ok, %{"tls.crt" => "CERT", "tls.key" => "KEY"}}
      end)

      expect(Secret, :create, 1, fn _kc, ns, "access-domain-cert-" <> _tail, _data, _labels ->
        assert ns == deployed.namespace
        {:ok, %{}}
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()
    end

    test "a needs_attention domain keeps its public routes", %{org: org, owner: owner} do
      # A :needs_attention row is a demotion OF a verified row — the
      # fixture reaches it the honest way (register → verify → flag).
      stub(Kubereq, :apply, fn _req, manifest, _fm ->
        {:ok, %{status: 201, body: manifest}}
      end)

      domain = AccessFixtures.needs_attention_domain!(org)
      {instance, row} = public_hostname!(org, owner, domain)

      name = custom_name_for(row)

      stub(Ingress, :list_by_labels, fn _kc, _ns, _labels ->
        {:ok,
         [
           route_body(instance.namespace, name, domain.id),
           route_body(instance.namespace, name <> "-dav", domain.id)
         ]}
      end)

      stub(Ingress, :delete, fn _kc, _ns, _name ->
        flunk("a needs_attention domain keeps serving — nothing comes down")
      end)

      stub(EdgeRoutes, :apply_public_for_status, fn _kc, sent_instance ->
        send(self(), {:reapplied, sent_instance.id})
        :ok
      end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      # An ALREADY-flagged row stands (observed Ready=False on a
      # needs_attention row is :unchanged) — and the drift sweep still
      # walks it: needs_attention keeps serving, so both siblings are
      # re-applied, none deleted.
      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :needs_attention

      assert_received {:reapplied, _}
      assert_received {:reapplied, _}
    end

    test "routes with no live justification come down — gone, stopped, unlabeled", %{
      org: org,
      owner: owner
    } do
      gone_id = Ecto.UUID.generate()

      platform =
        Ash.Seed.seed!(AccessDomain, %{
          organization_id: org.id,
          domain: "fleet.example.com",
          kind: :platform,
          state: :verified,
          registered_at: hours_ago(1)
        })

      stopped =
        Ash.Seed.seed!(AccessDomain, %{
          organization_id: org.id,
          domain: "parked.example.com",
          kind: :custom,
          state: :suspended,
          registered_at: hours_ago(1)
        })

      walked = seed_verified_domain(org, "walked.example.com")
      {instance, _row} = public_hostname!(org, owner, walked)
      namespace = instance.namespace

      stub(Ingress, :list_by_labels, fn _kc, _ns, _labels ->
        {:ok,
         [
           route_body(namespace, "custom-0a0a0a0a0a", gone_id),
           route_body(namespace, "custom-1b1b1b1b1b", platform.id),
           route_body(namespace, "custom-2c2c2c2c2c", stopped.id),
           %{"metadata" => %{"name" => "custom-3d3d3d3d3d", "namespace" => namespace}}
         ]}
      end)

      stub(Ingress, :delete, fn _kc, ^namespace, name ->
        send(self(), {:stale_removed, name})

        if name == "custom-2c2c2c2c2c" do
          {:error, :delete_refused}
        else
          :ok
        end
      end)

      stub(EdgeRoutes, :apply_public_for_status, fn _kc, _instance ->
        flunk("an unjustified route is never re-applied")
      end)

      stub_cert_replica()

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      # A failed delete is warn-only — the pass still lands.
      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()

      # Domain gone (label points nowhere), a platform-labeled route
      # (the public family never mints one), a domain no longer
      # serving, and a route with no label at all: all four come down.
      assert_received {:stale_removed, "custom-0a0a0a0a0a"}
      assert_received {:stale_removed, "custom-1b1b1b1b1b"}
      assert_received {:stale_removed, "custom-2c2c2c2c2c"}
      assert_received {:stale_removed, "custom-3d3d3d3d3d"}
    end

    test "a drift-sweep listing failure is warn-only — the pass still lands", %{
      org: org,
      owner: owner
    } do
      domain = seed_verified_domain(org, "quiet.example.com")
      {_instance, _row} = public_hostname!(org, owner, domain)

      stub(Ingress, :list_by_labels, fn _kc, _ns, _labels ->
        {:error, :list_refused}
      end)

      stub_cert_replica()

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 0}} = Infrastructure.verify_access_domains()
    end

    test "one domain serves a public and a private sibling without crossing", %{
      org: org,
      owner: owner
    } do
      domain = register!(owner)
      {public, public_row} = public_hostname!(org, owner, domain)
      {private, _gateway} = attached_hostname!(org, owner, domain)

      private_row =
        domain.id
        |> hostname_rows()
        |> Enum.find(&(&1.instance_id == private.id))

      stub_cert_replica()

      stub(Service, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)
      stub(Middleware, :create, fn _kc, _ns, _name, _spec -> {:ok, %{}} end)

      stub(Ingress, :create, fn _kc, ns, name, spec ->
        send(self(), {:route_created, ns, name, spec})
        {:ok, %{}}
      end)

      stub(SyncInstanceUrlEnv, :call, fn _instance -> :ok end)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("True")}}
      end)

      assert {:ok, %{verified: 1}} = Infrastructure.verify_access_domains()

      routes = drain_routes([])

      # The public sibling: its custom route rides websecure with NO
      # ClientIP clause.
      {_ns, _name, public_spec} =
        Enum.find(routes, fn {ns, name, _spec} ->
          ns == public.namespace and name == custom_name_for(public_row)
        end)

      refute Map.has_key?(public_spec, :source_ip)
      refute Map.has_key?(public_spec, :entrypoint)

      public_manifest =
        Ingress.build_manifest(public.namespace, custom_name_for(public_row), public_spec)

      assert public_manifest["spec"]["entryPoints"] == ["websecure"]

      # The private sibling: its access route keeps the ClientIP clause
      # (the gateway's pod IP, the Am. 6 shape).
      {_ns, _name, private_spec} =
        Enum.find(routes, fn {ns, name, _spec} ->
          ns == private.namespace and name == access_name_for(private_row)
        end)

      private_manifest =
        Ingress.build_manifest(private.namespace, access_name_for(private_row), private_spec)

      private_match =
        private_manifest["spec"]["routes"]
        |> List.first()
        |> Map.fetch!("match")

      assert private_match =~ "ClientIP(`10.0.0.9/32`)"

      # Neither instance mints the other's family.
      refute Enum.any?(routes, fn {ns, name, _spec} ->
               ns == public.namespace and String.starts_with?(name, "access-")
             end)

      refute Enum.any?(routes, fn {ns, name, _spec} ->
               ns == private.namespace and String.starts_with?(name, "custom-")
             end)
    end
  end
end
