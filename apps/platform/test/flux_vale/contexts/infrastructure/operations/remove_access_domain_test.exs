defmodule FluxVale.Infrastructure.Operations.RemoveAccessDomainTest do
  @moduledoc false

  # ADR-0040 S1's removal contract: :custom only, refused while any
  # hostname still references the domain, Certificate safe-deleted
  # (404 tolerated) before the row goes.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(Kubereq, :attach, fn req, _opts -> req end)

    {org, owner} = BillingFixtures.grant_free_org!()
    # Instance create resolves the platform's cluster (ResolveCluster);
    # the fixture builds it through the action (authorize?: false).
    InstanceFixtures.local_cluster!()

    {:ok, org: org, owner: owner}
  end

  describe "remove/2" do
    test "refuses while a hostname references the domain (the FK is the guard), then succeeds without one",
         %{org: org, owner: owner} do
      domain = register_custom_domain!(owner)
      instance = instance!(org, owner)

      # authorize?: false — the precondition is a hostname the S2 lanes
      # will re-home; minting here is system posture (the resource's own
      # :mint is system-only). Minted AFTER the operation's authorized
      # read can have seen the row — the race a pre-check read could
      # never close; the FK restrict catches it.
      hostname =
        InstanceHostname.mint!(
          %{instance_id: instance.id, access_domain_id: domain.id, label: "app"},
          authorize?: false
        )

      # No cluster call may happen while the row stands — the Certificate
      # is only ever deleted after a successful destroy.
      stub(Kubereq, :delete, fn _req, _ns, _name -> flunk("no cluster call expected") end)

      assert {:error, :hostnames_present} =
               Infrastructure.remove_access_domain(domain, actor: owner)

      assert still_there?(domain.id)

      assert :ok = InstanceHostname.destroy(hostname, authorize?: false)

      expect(Kubereq, :delete, fn _req, ns, name ->
        assert ns == Application.fetch_env!(:flux_vale, :access_domains)[:certificate_namespace]
        assert name == AccessDomain.certificate_name(domain)
        {:ok, %{status: 200}}
      end)

      assert :ok = Infrastructure.remove_access_domain(domain, actor: owner)
      refute still_there?(domain.id)
    end

    test "a non-FK destroy failure passes through unmapped", %{owner: owner} do
      domain = register_custom_domain!(owner)

      stub(Kubereq, :delete, fn _req, _ns, _name -> flunk("no cluster call expected") end)
      stub(AccessDomain, :remove, fn _domain, _opts -> {:error, :forced_other_failure} end)

      assert {:error, :forced_other_failure} =
               Infrastructure.remove_access_domain(domain, actor: owner)

      assert still_there?(domain.id)
    end

    test "a 404 on the Certificate delete is tolerated (safe-delete)", %{owner: owner} do
      domain = register_custom_domain!(owner)

      expect(Kubereq, :delete, fn _req, _ns, _name ->
        {:ok, %{status: 404, body: %{}}}
      end)

      assert :ok = Infrastructure.remove_access_domain(domain, actor: owner)
      refute still_there?(domain.id)
    end

    test "a cluster delete failure after the row is gone is the accepted residue", %{owner: owner} do
      domain = register_custom_domain!(owner)

      expect(Kubereq, :delete, fn _req, _ns, _name ->
        {:error, :transport_oops}
      end)

      # The row goes first (P1-3's order): a failing Certificate delete
      # afterwards leaves the row REMOVED and returns the error — the
      # orphaned object is the documented residue (S3's sweep owns it),
      # never live TLS state deleted under a standing row.
      assert {:error, _reason} = Infrastructure.remove_access_domain(domain, actor: owner)
      refute still_there?(domain.id)
    end

    test "the platform kind is refused before anything is touched", %{org: org, owner: owner} do
      # authorize?: false — the platform row is system-minted.
      platform =
        AccessDomain.mint_platform!(
          %{
            domain: Application.fetch_env!(:flux_vale, :instances_base_domain),
            organization_id: org.id
          },
          authorize?: false
        )

      stub(Kubereq, :delete, fn _req, _ns, _name -> flunk("no cluster call expected") end)

      assert {:error, :platform_kind} =
               Infrastructure.remove_access_domain(platform, actor: owner)

      assert still_there?(platform.id)
    end

    test "the :remove action's own guard also refuses the platform kind", %{org: org} do
      platform =
        AccessDomain.mint_platform!(
          %{
            domain: Application.fetch_env!(:flux_vale, :instances_base_domain),
            organization_id: org.id
          },
          authorize?: false
        )

      assert {:error, _changeset} = AccessDomain.remove(platform, authorize?: false)
    end

    test "a member of another org cannot remove (Forbidden before any cluster call)", %{
      owner: owner
    } do
      domain = register_custom_domain!(owner)
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()

      stub(Kubereq, :delete, fn _req, _ns, _name -> flunk("no cluster call expected") end)

      assert {:error, _forbidden} =
               Infrastructure.remove_access_domain(domain, actor: other_owner)

      assert still_there?(domain.id)
    end
  end

  # ------------------------------------------------------------------
  # The unclaim limb (ADR-0040 S3): before the destroy, the org's
  # gateway loses the domain's tailnet claim. Failure FAILS the remove.
  # ------------------------------------------------------------------

  describe "remove/2 — the unclaim limb" do
    setup do
      stub(Tailscale, :provision_gateway, fn _gateway, _key ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      :ok
    end

    test "a claimed domain is un-claimed BEFORE the row goes", %{org: org, owner: owner} do
      domain = register_custom_domain!(owner)

      gateway =
        update_claims!(
          AccessFixtures.gateway!(org),
          %{domain.domain => "10.43.0.20"}
        )

      stub(Tailscale, :unclaim_domain, fn gw, domain_name ->
        assert gw.id == gateway.id
        assert domain_name == domain.domain
        :ok
      end)

      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200, body: %{}}} end)

      assert :ok = Infrastructure.remove_access_domain(domain, actor: owner)
      refute still_there?(domain.id)

      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims == %{}
    end

    test "an unclaim failure fails the remove — no dangling tailnet state", %{
      org: org,
      owner: owner
    } do
      domain = register_custom_domain!(owner)

      gateway =
        update_claims!(
          AccessFixtures.gateway!(org),
          %{domain.domain => "10.43.0.20"}
        )

      stub(Tailscale, :unclaim_domain, fn _gw, _d -> {:error, :unauthorized} end)

      stub(Kubereq, :delete, fn _req, _ns, _name ->
        flunk("the row must stand while unclaim fails")
      end)

      assert {:error, {:unclaim_failed, :unauthorized}} =
               Infrastructure.remove_access_domain(domain, actor: owner)

      assert still_there?(domain.id)

      # The row's claims are untouched too — the retry re-runs the limb.
      row = AccessGateway.get_by_id!(gateway.id, authorize?: false)
      assert row.dns_claims == %{domain.domain => "10.43.0.20"}
    end

    # P1-2: the unset is UNCONDITIONAL — a claims map without the entry
    # does not mean the tailnet is clean (the entry can have been lost
    # to a racing write while the routes stood). The PATCH nil is
    # idempotent; the retry re-attempts regardless.
    test "a gateway without a claim entry still un-claims (the unset is idempotent)", %{
      org: org,
      owner: owner
    } do
      domain = register_custom_domain!(owner)
      gateway = AccessFixtures.gateway!(org)

      stub(Tailscale, :unclaim_domain, fn gw, domain_name ->
        assert gw.id == gateway.id
        assert domain_name == domain.domain
        :ok
      end)

      expect(Kubereq, :delete, fn _req, _ns, _name -> {:ok, %{status: 200, body: %{}}} end)

      assert :ok = Infrastructure.remove_access_domain(domain, actor: owner)
      refute still_there?(domain.id)
    end

    # P1-2's step (1): the hostname guard runs BEFORE the tailnet
    # write — a refused remove never touches the owner's tailnet.
    test "a hostname-guarded remove makes no tailnet call at all", %{org: org, owner: owner} do
      domain = register_custom_domain!(owner)
      instance = instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)

      InstanceHostname.mint!(
        %{instance_id: instance.id, access_domain_id: domain.id, label: "app"},
        authorize?: false
      )

      stub(Tailscale, :unclaim_domain, fn _gw, _d ->
        flunk("the hostname guard precedes any tailnet write")
      end)

      assert {:error, :hostnames_present} =
               Infrastructure.remove_access_domain(domain, actor: owner)

      assert still_there?(domain.id)
      assert gateway.id
    end

    # P3-9: only the not-found shape means "no gateway, nothing to
    # un-claim" — any other gateway-lookup failure propagates and fails
    # the remove instead of silently skipping the tailnet half.
    test "a non-not-found gateway lookup failure fails the remove", %{owner: owner} do
      domain = register_custom_domain!(owner)

      stub(AccessGateway, :get_for_organization, fn _org_id, _opts ->
        {:error, :db_oops}
      end)

      stub(Kubereq, :delete, fn _req, _ns, _name -> flunk("the row must stand") end)

      assert {:error, :db_oops} = Infrastructure.remove_access_domain(domain, actor: owner)
      assert still_there?(domain.id)
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # The system funnel for the claims map (never a raw write — the same
  # seam the claiming ops land through).
  defp update_claims!(gateway, claims) do
    Ash.update!(gateway, %{dns_claims: claims},
      action: :update_claims,
      authorize?: false
    )
  end

  defp register_custom_domain!(owner) do
    expect(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    assert {:ok, domain} =
             Infrastructure.register_access_domain(%{domain: "apps.customer.com"}, actor: owner)

    domain
  end

  # The real action path: instance create now mints the org's platform
  # row + default hostname as a side effect (its own suite pins that).
  defp instance!(org, owner) do
    {org, _wallet} = BillingFixtures.funded_wallet!(org: org)
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    assert instance.organization_id == org.id
    instance
  end

  defp still_there?(id) do
    match?({:ok, %AccessDomain{}}, AccessDomain.get_by_id(id, authorize?: false))
  end
end
