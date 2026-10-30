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
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
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
  # Helpers
  # ------------------------------------------------------------------

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
