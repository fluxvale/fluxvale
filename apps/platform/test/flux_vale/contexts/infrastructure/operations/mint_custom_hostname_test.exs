defmodule FluxVale.Infrastructure.Operations.MintCustomHostnameTest do
  @moduledoc false

  # S6 (#751): the member's custom-address mint. The instance read is
  # the ownership fence; the domain must belong to the instance's org,
  # be :custom, and be :verified; an attached instance's edge re-applies
  # (and the row unwinds when that fails); the resolver render is
  # best-effort after commit.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Accounts.Membership
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.EdgeRoutes
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  setup do
    verify_on_exit!()

    stub(Kubereq, :attach, fn req, _opts -> req end)

    stub(Kubereq, :apply, fn _req, manifest, _fm ->
      {:ok, %{status: 201, body: manifest}}
    end)

    stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    {org, owner} = BillingFixtures.grant_free_org!()
    {^org, _wallet} = BillingFixtures.funded_wallet!(org: org)
    InstanceFixtures.local_cluster!()

    {:ok, org: org, owner: owner}
  end

  describe "call/4 — the happy paths" do
    test "mints the row under a verified custom domain, unattached (no cluster call)", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)

      expect(RenderAccessDNS, :call, fn -> :ok end)
      reject(EdgeRoutes, :apply_access_for_status, 3)

      assert {:ok, hostname} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)

      assert hostname.label == "git"
      assert hostname.instance_id == instance.id
      assert hostname.access_domain_id == domain.id
    end

    test "records the row without re-minting a public attached instance's edge", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = public_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)

      expect(RenderAccessDNS, :call, fn -> :ok end)
      reject(EdgeRoutes, :apply_access_for_status, 3)

      assert {:ok, _hostname} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)

      assert hostname_exists?(instance.id, "git")
    end

    test "applies the access edge for an attached private instance's current status", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      route = route!(gateway, instance)

      expect(EdgeRoutes, :apply_access_for_status, fn kubeconfig, sent_gateway, sent_instance ->
        assert kubeconfig == %{}
        assert sent_gateway.id == gateway.id
        assert sent_instance.id == instance.id
        :ok
      end)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _hostname} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)

      assert route.gateway_id == gateway.id
    end
  end

  describe "call/4 — the guards" do
    test "a platform domain is refused", %{org: org, owner: owner} do
      instance = instance!(org, owner)

      platform =
        AccessDomain
        |> Ash.Query.filter(organization_id == ^org.id and kind == :platform)
        |> Ash.read_one!(authorize?: false)

      reject(RenderAccessDNS, :call, 0)
      reject(EdgeRoutes, :apply_access_for_status, 3)

      assert {:error, :not_custom} =
               Infrastructure.mint_custom_hostname(instance.id, platform.id, "git", actor: owner)
    end

    test "an unverified custom domain is refused", %{org: org, owner: owner} do
      domain = custom_domain!(org)
      instance = instance!(org, owner)

      reject(RenderAccessDNS, :call, 0)
      reject(EdgeRoutes, :apply_access_for_status, 3)

      assert {:error, :not_verified} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)
    end

    test "a domain owned by another org is refused when the actor can read both", %{
      org: org,
      owner: owner
    } do
      instance = instance!(org, owner)
      {other_org, _other_owner} = BillingFixtures.grant_free_org!()

      # The actor's second membership makes both authorized reads pass,
      # so the operation's own org fence is what bites.
      Membership.create!(
        %{organization_id: other_org.id, user_id: owner.id, role: :member},
        authorize?: false
      )

      foreign_domain = verified_domain!(other_org)

      reject(RenderAccessDNS, :call, 0)
      reject(EdgeRoutes, :apply_access_for_status, 3)

      assert {:error, :different_organization} =
               Infrastructure.mint_custom_hostname(
                 instance.id,
                 foreign_domain.id,
                 "git",
                 actor: owner
               )
    end

    test "a foreign instance is a not-found — never a distinguishable 403", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = instance!(org, owner)
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()

      reject(RenderAccessDNS, :call, 0)

      assert {:error, _not_found} =
               Infrastructure.mint_custom_hostname(
                 instance.id,
                 domain.id,
                 "git",
                 actor: other_owner
               )
    end

    test "an invalid label is refused before any row lands", %{org: org, owner: owner} do
      domain = verified_domain!(org)
      instance = instance!(org, owner)

      reject(RenderAccessDNS, :call, 0)

      assert {:error, _changeset} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "Git", actor: owner)
    end

    test "an unknown domain id is a not-found", %{org: org, owner: owner} do
      instance = instance!(org, owner)

      reject(RenderAccessDNS, :call, 0)

      assert {:error, _not_found} =
               Infrastructure.mint_custom_hostname(
                 instance.id,
                 Ash.UUID.generate(),
                 "git",
                 actor: owner
               )
    end
  end

  describe "call/4 — the edge unwind" do
    test "a failed edge apply destroys the just-minted row and its partial route", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)

      expect(EdgeRoutes, :apply_access_for_status, fn _kc, _gateway, _instance ->
        {:error, :edge_refused}
      end)

      expect(EdgeRoutes, :apply_access_none_for_hostname, fn _kc, _instance, hostname ->
        assert hostname.label == "git"
        :ok
      end)

      reject(RenderAccessDNS, :call, 0)

      assert {:error, :edge_refused} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)

      refute hostname_exists?(instance.id, "git")
    end

    test "keeps the row when route cleanup fails, so a later remove converges", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)

      expect(EdgeRoutes, :apply_access_for_status, fn _kc, _gateway, _instance ->
        {:error, :edge_refused}
      end)

      expect(EdgeRoutes, :apply_access_none_for_hostname, fn _kc, _instance, _hostname ->
        {:error, :cleanup_boom}
      end)

      reject(RenderAccessDNS, :call, 0)

      assert {:error, :cleanup_boom} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)

      # The row stands with its route name, so remove can delete the
      # route first and then the row.
      assert hostname_exists?(instance.id, "git")
    end

    test "a kubeconfig failure unwinds the row without an edge cleanup call", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)

      stub(K8s, :kubeconfig, fn _ref -> {:error, :no_cluster} end)
      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)
      reject(RenderAccessDNS, :call, 0)

      assert {:error, :no_cluster} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)

      refute hostname_exists?(instance.id, "git")
    end

    test "a route-read failure unwinds the row (never a route-less claim)", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)

      stub(AccessRoute, :get_by_instance, fn _id, _opts -> {:error, :db_oops} end)
      reject(RenderAccessDNS, :call, 0)

      assert {:error, :db_oops} =
               Infrastructure.mint_custom_hostname(instance.id, domain.id, "git", actor: owner)

      refute hostname_exists?(instance.id, "git")
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp public_instance!(org, owner) do
    instance = instance!(org, owner)
    InstanceFixtures.pin!(instance, exposure: :public)
  end

  defp private_instance!(org, owner) do
    instance = instance!(org, owner)
    InstanceFixtures.pin!(instance, exposure: :private)
  end

  defp instance!(org, owner) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    assert instance.organization_id == org.id
    instance
  end

  defp route!(gateway, instance) do
    AccessRoute.create!(
      %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
      authorize?: false
    )
  end

  defp custom_domain!(org) do
    name = "apps-#{System.unique_integer([:positive])}.customer.test"

    AccessDomain.register!(
      %{domain: name, organization_id: org.id},
      actor: org_actor!(org.id),
      authorize?: false
    )
  end

  # The register action's org change needs an actor even with a named
  # org (the fixture's bootstrap posture); the owner is the honest one.
  defp org_actor!(organization_id) do
    Membership
    |> Ash.Query.filter(organization_id == ^organization_id and role == :owner)
    |> Ash.read_one!(authorize?: false)
  end

  defp verified_domain!(org) do
    domain = custom_domain!(org)
    {:ok, verified} = AccessDomain.mark_verified(domain, authorize?: false)
    verified
  end

  defp hostname_exists?(instance_id, label) do
    InstanceHostname
    |> Ash.Query.filter(instance_id == ^instance_id and label == ^label)
    |> Ash.exists?(authorize?: false)
  end
end
