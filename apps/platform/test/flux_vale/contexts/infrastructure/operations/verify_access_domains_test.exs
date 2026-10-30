defmodule FluxVale.Infrastructure.Operations.VerifyAccessDomainsTest do
  @moduledoc false

  # ADR-0040 S1's verify-by-issuance ladder: the observer pass is the
  # ONLY promoter to :verified (issuance success IS the verification),
  # the deadline fails a stalled :pending, and observed states self-heal
  # (:verified ⇄ :needs_attention) — the gateway-observer stance.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.TestSupport.BillingFixtures

  @deadline_hours 72

  setup do
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    {org, owner} = BillingFixtures.grant_free_org!()

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

    test "a missing Certificate inside the window is drift a retry covers — left :pending", %{
      owner: owner
    } do
      domain = register!(owner)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      assert {:ok, %{verified: 0, failed: 0, needs_attention: 0}} =
               Infrastructure.verify_access_domains()

      assert get_row!(domain.id).state == :pending
    end

    test "a missing Certificate past the deadline -> :failed", %{org: org} do
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

    test ":verified whose Certificate vanished lands :needs_attention", %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      assert {:ok, %{needs_attention: 1}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :needs_attention
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

    test ":needs_attention with no Ready=True yet stands", %{owner: owner} do
      domain = register!(owner)
      promote_to_verified!(domain)

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 200, body: cert_body("False")}}
      end)

      assert {:ok, _counts} = Infrastructure.verify_access_domains()

      expect(Kubereq, :get, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      assert {:ok, %{verified: 0, needs_attention: 0}} = Infrastructure.verify_access_domains()
      assert get_row!(domain.id).state == :needs_attention
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
    test "mark_suspended lands :suspended — no writer yet, the billing ladder owns it", %{
      owner: owner
    } do
      domain = register!(owner)

      assert {:ok, suspended} = AccessDomain.mark_suspended(domain, authorize?: false)
      assert suspended.state == :suspended
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

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
end
