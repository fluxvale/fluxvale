defmodule FluxVale.Infrastructure.Operations.RegisterAccessDomainTest do
  @moduledoc false

  # ADR-0040 S1's registration contract: the row lands :pending (it
  # claims nothing), the wildcard Certificate goes out in the same
  # transaction, and a cluster failure leaves no row behind.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  setup do
    # The ops resolve the platform kubeconfig + attach the Kubereq req;
    # both stubbed so the cluster calls below are the only cluster.
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    {org, owner} = BillingFixtures.grant_free_org!()

    {:ok, org: org, owner: owner}
  end

  describe "register/2" do
    test "creates the row :pending and applies the wildcard Certificate", %{
      org: org,
      owner: owner
    } do
      config = Application.fetch_env!(:flux_vale, :access_domains)

      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["kind"] == "Certificate"
        assert manifest["metadata"]["namespace"] == config[:certificate_namespace]
        assert manifest["spec"]["dnsNames"] == ["*.apps.customer.com"]
        assert manifest["spec"]["secretName"] =~ ~r/^access-domain-[0-9a-f]{10}$/
        assert manifest["spec"]["issuerRef"]["name"] == config[:issuer]

        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, domain} =
               Infrastructure.register_access_domain(
                 %{domain: "apps.customer.com"},
                 actor: owner
               )

      assert domain.organization_id == org.id
      assert domain.kind == :custom
      # The core promise: the row claims NOTHING until the observer has
      # read the cluster (verify-by-issuance).
      assert domain.state == :pending
      assert domain.cert_secret_ref == nil
      assert domain.registered_at
    end

    test "normalizes the domain (trimmed + downcased) before storing", %{owner: owner} do
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        assert manifest["spec"]["dnsNames"] == ["*.apps.customer.com"]
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, domain} =
               Infrastructure.register_access_domain(
                 %{domain: "  Apps.Customer.COM  "},
                 actor: owner
               )

      assert domain.domain == "apps.customer.com"
    end

    test "a cluster failure fails the registration and no row survives", %{owner: owner} do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 500, body: %{"message" => "apiserver down"}}}
      end)

      # The rollback cleanup: one best-effort delete of what the attempt
      # may have landed.
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200}} end)

      assert {:error, _reason} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: owner
               )

      refute exists?("apps.customer.com")
    end

    test "a failed rollback cleanup still returns the original error", %{owner: owner} do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 500, body: %{}}}
      end)

      expect(Kubereq, :delete, fn _req, _ns, _name -> {:error, :transport_oops} end)

      assert {:error, _reason} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: owner
               )

      refute exists?("apps.customer.com")
    end

    test "a rollback cleanup finding nothing (404) is tolerated", %{owner: owner} do
      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 500, body: %{}}}
      end)

      # The attempt's object never landed — the cleanup's 404 is the
      # "gone is the goal" arm.
      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 404, body: %{}}} end)

      assert {:error, _reason} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: owner
               )

      refute exists?("apps.customer.com")
    end

    test "a missing domain errors without reaching the registrability probe", %{owner: owner} do
      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{}, actor: owner)
    end

    test "the system path (no actor) cannot register — the tenancy change leaves the org unset",
         %{
           owner: _owner
         } do
      # authorize?: false skips policies entirely, so this is the only
      # way to reach the change's no-actor clause: the org stays unset
      # and the insert refuses (organization_id is required).
      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{domain: "system.example.com"},
                 authorize?: false
               )

      refute exists?("system.example.com")
    end

    test "an unreachable cluster fails the registration with nothing to clean", %{owner: owner} do
      stub(K8s, :kubeconfig, fn -> {:error, "no in-cluster kubeconfig"} end)

      stub(Kubereq, :apply, fn _req, _manifest, _fm ->
        flunk("no cluster call expected without a kubeconfig")
      end)

      assert {:error, _reason} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: owner
               )

      refute exists?("apps.customer.com")
    end

    test "a malformed domain is rejected before any cluster call", %{owner: owner} do
      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{domain: "not a domain!"}, actor: owner)
    end

    test "a domain over RFC 253's bound minus the wildcard star is rejected", %{owner: owner} do
      # 252 chars of well-shaped labels: one past the 251 max_length
      # (RFC 253's 253-octet printable name minus the "*." the
      # Certificate's dnsName adds).
      too_long = String.duplicate("ab.", 83) <> "abc"
      assert String.length(too_long) == 252

      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{domain: too_long}, actor: owner)
    end

    test "the platform base domain is refused", %{owner: owner} do
      base = Application.fetch_env!(:flux_vale, :instances_base_domain)

      stub(Kubereq, :apply, fn _req, _manifest, _fm ->
        flunk("no cluster call expected for the platform domain")
      end)

      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{domain: base}, actor: owner)

      refute exists?(base)
    end

    test "a custom domain already held by ANOTHER org is refused", %{owner: owner} do
      register_domain!(owner)
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()

      stub(Kubereq, :apply, fn _req, _manifest, _fm ->
        flunk("no cluster call expected for a taken domain")
      end)

      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: other_owner
               )

      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{domain: "apps.customer.com"},
                 actor: owner
               )
    end

    test "org A cannot take a domain org B registered first", %{owner: owner} do
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()

      # org B registers first — exactly one apply is expected; a buggy
      # refusal that still reaches the cluster would fire a second call
      # and fail the expectation.
      expect(Kubereq, :apply, fn _req, manifest, _fm ->
        {:ok, %{status: 201, body: manifest}}
      end)

      assert {:ok, _domain} =
               Infrastructure.register_access_domain(%{domain: "taken.example.com"},
                 actor: other_owner
               )

      assert {:error, _changeset} =
               Infrastructure.register_access_domain(%{domain: "taken.example.com"},
                 actor: owner
               )
    end

    test "the partial unique index is the race backstop — a double-mint cannot commit", %{
      org: org
    } do
      # Ash.seed!, not actions: the race this pins is two registers
      # passing the read probe together — only the constraint sees them.
      # authorize?: false — system precondition (the same seed stance as
      # the aged-pending rows).
      Ash.Seed.seed!(AccessDomain, %{
        organization_id: org.id,
        domain: "raced.example.com",
        kind: :custom,
        state: :pending,
        registered_at: DateTime.utc_now()
      })

      {other_org, _owner} = BillingFixtures.grant_free_org!()

      # ash_postgres maps the unique violation to a field error — the
      # message names the domain (the per-org identity could not fire:
      # different orgs).
      assert_raise Ash.Error.Invalid, ~r/already been taken/, fn ->
        Ash.Seed.seed!(AccessDomain, %{
          organization_id: other_org.id,
          domain: "raced.example.com",
          kind: :custom,
          state: :pending,
          registered_at: DateTime.utc_now()
        })
      end
    end
  end

  describe "policies" do
    test "a member of another org reads nothing", %{org: org, owner: owner} do
      domain = register_domain!(owner)

      {other_org, other_owner} = BillingFixtures.grant_free_org!()
      refute other_org.id == org.id

      # Read policies filter: the other org's member sees an empty list
      # and cannot fetch the row.
      assert {:ok, []} = AccessDomain.list_all(actor: other_owner)
      assert {:error, _not_authorized} = AccessDomain.get_by_id(domain.id, actor: other_owner)
    end

    test "registering always lands in the ACTOR's org — a cross-org row is unreachable", %{
      org: org,
      owner: owner
    } do
      register_domain!(owner)
      {other_org, other_owner} = BillingFixtures.grant_free_org!()

      expect(Kubereq, :apply, fn _req, _manifest, _fm ->
        {:ok, %{status: 201, body: %{}}}
      end)

      assert {:ok, domain} =
               Infrastructure.register_access_domain(%{domain: "other.example.com"},
                 actor: other_owner
               )

      # The org is forced from the actor (SetOrganizationFromActor) — the
      # row can never mint into another org.
      assert domain.organization_id == other_org.id
      refute domain.organization_id == org.id
    end

    test "an actor with no org cannot register anywhere" do
      # Ash.seed!, not the create action: JIT provisioning gives every
      # action-created user a personal org — an org-less user is a state
      # actions cannot produce (the SetOrganizationFromActor stance).
      orgless =
        Ash.Seed.seed!(FluxVale.Identity.User, %{
          email: "orgless-#{System.unique_integer([:positive])}@fluxvale.test"
        })

      assert {:error, _error} =
               Infrastructure.register_access_domain(%{domain: "nowhere.example.com"},
                 actor: orgless
               )

      refute exists?("nowhere.example.com")
    end
  end

  defp register_domain!(owner) do
    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: "apps.customer.com"}, actor: owner)

    domain
  end

  defp exists?(domain_name) do
    AccessDomain
    |> Ash.Query.filter(domain == ^domain_name)
    |> Ash.exists?(authorize?: false)
  end
end
