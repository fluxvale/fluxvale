defmodule FluxVale.Infrastructure.Operations.RemoveCustomHostnameTest do
  @moduledoc false

  # S6 (#751): the member's custom-address remove — edge routes first,
  # then the row, then the best-effort resolver render. The default
  # platform address is not removable; an unattached instance has no
  # cluster limb.

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
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.Infrastructure.Operations.RenderAccessDNS
  alias FluxVale.Infrastructure.Operations.SyncInstanceUrlEnv
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

  describe "call/2 — the happy paths" do
    test "removes an attached custom address: its routes first, then the row", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)

      hostname = hostname!(instance, domain, "git")

      expect(EdgeRoutes, :apply_access_none_for_hostname, fn kubeconfig,
                                                             sent_instance,
                                                             sent_hostname ->
        assert kubeconfig == %{}
        assert sent_instance.id == instance.id
        assert sent_hostname.id == hostname.id
        :ok
      end)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, removed} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      assert removed.id == hostname.id
      refute hostname_exists?(hostname.id)
    end

    test "removes an unattached instance's address without touching the cluster", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)
      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _removed} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      refute hostname_exists?(hostname.id)
    end
  end

  describe "call/2 — refusals and failures" do
    test "the default platform address is not removable", %{org: org, owner: owner} do
      instance = instance!(org, owner)

      default =
        InstanceHostname
        |> Ash.Query.filter(instance_id == ^instance.id)
        |> Ash.read_one!(authorize?: false)

      reject(RenderAccessDNS, :call, 0)
      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)

      assert {:error, :platform_domain} =
               Infrastructure.remove_custom_hostname(default.id, actor: owner)

      assert hostname_exists?(default.id)
    end

    test "a route-delete failure leaves the row standing (the retry converges)", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)
      hostname = hostname!(instance, domain, "git")

      stub(EdgeRoutes, :apply_access_none_for_hostname, fn _kc, _instance, _hostname ->
        {:error, :edge_refused}
      end)

      reject(RenderAccessDNS, :call, 0)

      assert {:error, :edge_refused} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      assert hostname_exists?(hostname.id)
    end

    test "a kubeconfig failure leaves the row standing", %{org: org, owner: owner} do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)
      hostname = hostname!(instance, domain, "git")

      stub(K8s, :kubeconfig, fn _ref -> {:error, :no_cluster} end)
      reject(RenderAccessDNS, :call, 0)

      assert {:error, :no_cluster} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      assert hostname_exists?(hostname.id)
    end

    test "a route-read failure passes through and leaves the row standing", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      stub(AccessRoute, :get_by_instance, fn _id, _opts -> {:error, :db_oops} end)
      reject(RenderAccessDNS, :call, 0)

      assert {:error, :db_oops} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      assert hostname_exists?(hostname.id)
    end

    test "a non-stale destroy failure passes through and leaves the row standing", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      # Not a vanished row — a genuine destroy failure (the DB-outage
      # class): the error passes through and the row stands for the
      # retry.
      stub(InstanceHostname, :destroy, fn _record, _opts ->
        {:error, %Ash.Error.Invalid{errors: []}}
      end)

      reject(RenderAccessDNS, :call, 0)

      assert {:error, _error} = Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      assert hostname_exists?(hostname.id)
    end

    test "a non-member's address is a not-found before any cluster call", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = instance!(org, owner)
      hostname = hostname!(instance, domain, "git")
      {_other_org, other_owner} = BillingFixtures.grant_free_org!()

      reject(RenderAccessDNS, :call, 0)
      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)

      assert {:error, _not_found} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: other_owner)

      assert hostname_exists?(hostname.id)
    end

    test "an unknown id is a not-found", %{owner: owner} do
      reject(RenderAccessDNS, :call, 0)

      assert {:error, _not_found} =
               Infrastructure.remove_custom_hostname(Ash.UUID.generate(), actor: owner)
    end
  end

  describe "call/2 — the URL-env sync hook (the address re-tell)" do
    test "a serving attached private instance's remove syncs after the row is gone", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)
      hostname = hostname!(instance, domain, "git")

      expect(EdgeRoutes, :apply_access_none_for_hostname, fn _kc, _instance, _hostname ->
        :ok
      end)

      # The derivation must not see the row it just removed.
      expect(SyncInstanceUrlEnv, :call, fn synced ->
        refute hostname_exists?(hostname.id)
        assert synced.id == instance.id
        :ok
      end)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _removed} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      refute hostname_exists?(hostname.id)
    end

    test "a sync failure is warn-only — the remove still stands", %{org: org, owner: owner} do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      gateway = AccessFixtures.gateway!(org)
      _route = route!(gateway, instance)
      hostname = hostname!(instance, domain, "git")

      expect(EdgeRoutes, :apply_access_none_for_hostname, fn _kc, _instance, _hostname ->
        :ok
      end)

      stub(SyncInstanceUrlEnv, :call, fn _instance -> {:error, :missing} end)
      expect(RenderAccessDNS, :call, fn -> :ok end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _removed} =
                   Infrastructure.remove_custom_hostname(hostname.id, actor: owner)
        end)

      assert log =~ "instance address env sync after remove refused"
      assert log =~ instance.id
      refute hostname_exists?(hostname.id)
    end
  end

  describe "call/2 — the public plane (the remove unpublishes)" do
    test "a remove that lands public after a racing private-to-public toggle unpublishes the route",
         %{
           org: org,
           owner: owner
         } do
      domain = verified_domain!(org)
      instance = private_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      # The race, staged: the guard read (below) sees :private; the
      # toggle lands before the locked re-read, which sees :public and
      # dispatches the PUBLIC none limb — the route comes down with
      # the row, never orphaned.
      stale_private = Instance.get_by_id!(instance.id, authorize?: false)
      InstanceFixtures.pin!(instance, exposure: :public)

      id = instance.id

      stub(Instance, :get_by_id, fn
        ^id, _opts -> {:ok, stale_private}
        other_id, opts -> {:ok, Instance.get_by_id!(other_id, opts)}
      end)

      # The private limb never ran — the stale :private guard read did
      # not get its word in.
      reject(AccessRoute, :get_by_instance, 2)
      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)

      expect(EdgeRoutes, :apply_public_none_for_hostname, fn _kc, sent_instance, sent_hostname ->
        assert sent_instance.id == instance.id
        assert sent_hostname.id == hostname.id
        :ok
      end)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _removed} = Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      refute hostname_exists?(hostname.id)
    end

    test "a remove whose locked re-read vanishes still converges", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = public_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      # Teardown wins between the guard read and the locked re-read:
      # the instance (and its hostname rows, by cascade) is gone — the
      # edge limb finds nothing to remove and the remove completes
      # honestly (the row destroy's stale-record is the goal state
      # already holding).
      stub(Instance, :get_by_id, fn _id, _opts ->
        Ash.destroy!(instance, authorize?: false)
        {:ok, instance}
      end)

      # No edge limb ran — there is nothing to remove.
      reject(EdgeRoutes, :apply_public_none_for_hostname, 3)
      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)
      reject(InstanceK8s, :kubeconfig_for, 1)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _removed} = Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      refute hostname_exists?(hostname.id)
    end

    test "a never-deployed public instance removes the row without the cluster", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)

      # The undeployed shape the API remove meets: no namespace, :public.
      instance = instance!(org, owner)
      assert is_nil(instance.namespace)
      hostname = hostname!(instance, domain, "git")

      # The gate answers before any cluster seam — no kubeconfig
      # resolution, no route delete, no unwind; the row destroy is
      # DB-only.
      reject(InstanceK8s, :kubeconfig_for, 1)
      reject(EdgeRoutes, :apply_public_none_for_hostname, 3)
      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)
      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _removed} = Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      refute hostname_exists?(hostname.id)
    end

    test "a public instance's remove deletes the public route", %{org: org, owner: owner} do
      domain = verified_domain!(org)
      instance = public_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      # No pairing read — the exposure is the whole dispatch, and a
      # stale AccessRoute row must not detour the delete.
      reject(AccessRoute, :get_by_instance, 2)
      reject(EdgeRoutes, :apply_access_none_for_hostname, 3)

      expect(EdgeRoutes, :apply_public_none_for_hostname, fn kubeconfig,
                                                             sent_instance,
                                                             sent_hostname ->
        assert kubeconfig == %{}
        assert sent_instance.id == instance.id
        assert sent_hostname.id == hostname.id

        # The row still names the objects while they go — the orphan
        # prevention (a destroyed row can never be named by a later
        # walk).
        assert hostname_exists?(hostname.id)

        :ok
      end)

      # The re-tell runs after the row is gone (the derivation must not
      # see the row just removed).
      expect(SyncInstanceUrlEnv, :call, fn synced ->
        refute hostname_exists?(hostname.id)
        assert synced.id == instance.id
        :ok
      end)

      expect(RenderAccessDNS, :call, fn -> :ok end)

      assert {:ok, _removed} = Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      refute hostname_exists?(hostname.id)
    end

    test "a public route-delete failure leaves the row standing (the retry converges)", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = public_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      stub(EdgeRoutes, :apply_public_none_for_hostname, fn _kc, _instance, _hostname ->
        {:error, :edge_refused}
      end)

      reject(RenderAccessDNS, :call, 0)

      assert {:error, :edge_refused} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      assert hostname_exists?(hostname.id)
    end

    test "a kubeconfig failure leaves a public instance's row standing", %{
      org: org,
      owner: owner
    } do
      domain = verified_domain!(org)
      instance = public_instance!(org, owner)
      hostname = hostname!(instance, domain, "git")

      stub(K8s, :kubeconfig, fn _ref -> {:error, :no_cluster} end)
      reject(EdgeRoutes, :apply_public_none_for_hostname, 3)
      reject(RenderAccessDNS, :call, 0)

      assert {:error, :no_cluster} =
               Infrastructure.remove_custom_hostname(hostname.id, actor: owner)

      assert hostname_exists?(hostname.id)
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp public_instance!(org, owner) do
    instance = instance!(org, owner)

    # The DEPLOYED shape: the edge-limb tests stage an instance with a
    # namespace (a never-deployed row is the record-only gate's
    # subject).
    InstanceFixtures.pin!(instance,
      exposure: :public,
      namespace: "fluxvale-app-#{instance.id}"
    )
  end

  defp private_instance!(org, owner) do
    instance = instance!(org, owner)

    InstanceFixtures.pin!(instance,
      exposure: :private,
      namespace: "fluxvale-app-#{instance.id}"
    )
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

  defp hostname!(instance, domain, label) do
    InstanceHostname.mint!(
      %{instance_id: instance.id, access_domain_id: domain.id, label: label},
      authorize?: false
    )
  end

  defp hostname_exists?(id) do
    InstanceHostname
    |> Ash.Query.filter(id == ^id)
    |> Ash.exists?(authorize?: false)
  end
end
