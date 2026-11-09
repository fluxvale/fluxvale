defmodule FluxVale.Infrastructure.PaperTrailTest do
  @moduledoc false

  # The audit-trail proof on Infrastructure (#645, the plan's A2-S3
  # slice): the system machinery writes honest nil-actor rows (status
  # transitions, backup runs, routes, hostnames), member and operator
  # writes carry their actors, and the custody re-paste versions
  # create-or-update (observed, pinned). Mirrors the Billing suite
  # (the A2-S2 exemplar): version-row reads that assert STORAGE run
  # authorize?: false; the D7 version-read policy is pinned in Ops.

  use FluxVale.DataCase, async: true
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.AccessRoute
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.StorageRequestFixtures

  require Ash.Query

  defp versions!(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp member_instance!(user) do
    InstanceFixtures.local_cluster!()
    version = InstanceFixtures.app_version!()
    InstanceFixtures.instance!(version, user)
  end

  describe "the instance lifecycle leaves attributed evidence" do
    test "a member's instance create versions with that member" do
      user = AccountsFixtures.user!()

      instance = member_instance!(user)

      [create_version] = versions!(Instance.Version, instance.id)

      assert create_version.version_action_type == :create
      assert create_version.user_id == user.id
      assert create_version.actor_label == user.username
    end

    test "a system status transition versions with the honest nil actor" do
      user = AccountsFixtures.user!()
      instance = member_instance!(user)

      # The state machine's single funnel as the machinery drives it:
      # authorize?: false with no actor — the seeds/bootstrap posture.
      instance
      |> Ash.Changeset.for_update(
        :update_status,
        %{status: :deploying, status_message: "Deploying to Kubernetes..."},
        authorize?: false
      )
      |> Ash.update!()

      [_create_version, status_version] = versions!(Instance.Version, instance.id)

      assert status_version.version_action_name == :update_status
      assert is_nil(status_version.user_id)
      assert is_nil(status_version.actor_label)
      assert status_version.changes["status"] in [:deploying, "deploying"]

      # The touch/settle noise never versions (decision two, ADR-0048):
      # the beacon bookmark and the settle tick write zero rows.
      instance
      |> Ash.Changeset.for_update(:touch, %{}, authorize?: false)
      |> Ash.update!()

      assert length(versions!(Instance.Version, instance.id)) == 2
    end
  end

  describe "operator decisions carry their actor" do
    test "a storage-request approval versions the operator" do
      admin = AccountsFixtures.platform_admin!()
      user = AccountsFixtures.user!()
      instance = member_instance!(user)

      {:ok, org} = FluxVale.Accounts.personal_org_for_user(user.id, authorize?: false)
      BillingFixtures.funded_wallet!(org: org)

      running = InstanceFixtures.walk_to!(instance, :running)

      stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      request = StorageRequestFixtures.request!(running, user, %{requested_gb: 150})

      request
      |> Ash.Changeset.for_update(:approve, %{}, actor: admin)
      |> Ash.update!()

      [request_version, approve_version] = versions!(StorageRequest.Version, request.id)

      assert request_version.version_action_name == :request
      assert request_version.user_id == user.id

      assert approve_version.version_action_name == :approve
      assert approve_version.user_id == admin.id
      assert approve_version.actor_label == admin.username
    end
  end

  describe "custody and the system creates" do
    test "a custody re-paste versions create-or-update (observed, pinned)" do
      user = AccountsFixtures.user!()
      instance = member_instance!(user)

      now = DateTime.utc_now()

      custody =
        PocketIdCustody
        |> Ash.Changeset.for_create(
          :record,
          %{
            organization_id: instance.organization_id,
            instance_id: instance.id,
            api_key_secret_ref: "probe/ref/one",
            verified_at: now,
            expires_at: DateTime.add(now, 86_400)
          },
          authorize?: false
        )
        |> Ash.create!()

      custody
      |> Ash.Changeset.for_update(
        :record_replacement,
        %{
          api_key_secret_ref: "probe/ref/two",
          verified_at: now,
          expires_at: DateTime.add(now, 86_400)
        },
        authorize?: false
      )
      |> Ash.update!()

      versions = versions!(PocketIdCustody.Version, custody.id)

      # Observed and pinned: the re-paste is a plain update funnel, so
      # the trail reads create-then-update — one row per funnel write.
      assert Enum.map(versions, & &1.version_action_name) == [:record, :record_replacement]
      assert Enum.all?(versions, &is_nil(&1.user_id))
    end

    test "a backup run's system create versions with the nil actor" do
      user = AccountsFixtures.user!()
      instance = member_instance!(user)

      run =
        BackupRun
        |> Ash.Changeset.for_create(
          :create,
          %{
            instance_id: instance.id,
            kind: :scheduled,
            status: :succeeded,
            started_at: DateTime.utc_now()
          },
          authorize?: false
        )
        |> Ash.create!()

      [version] = versions!(BackupRun.Version, run.id)

      assert version.version_action_type == :create
      assert is_nil(version.user_id)
      assert is_nil(version.actor_label)
    end

    test "an access route's system create versions with the nil actor" do
      user = AccountsFixtures.user!()
      instance = member_instance!(user)

      # The gateway fixture provisions (Tailscale) — stub the provider
      # seam like the gateway suites do; the paid/funded pair rides the
      # org's wallet fixtures.
      stub(Tailscale, :provision_gateway, fn _gateway, _key ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      stub(Tailscale, :scale_gateway, fn _gateway, _replicas -> :ok end)
      stub(Tailscale, :teardown_gateway, fn _gateway -> :ok end)
      stub(Tailscale, :update_credential, fn _gateway, _key -> :ok end)

      {:ok, org} = FluxVale.Accounts.personal_org_for_user(user.id, authorize?: false)
      BillingFixtures.mark_paid!(org)
      BillingFixtures.funded_wallet!(org: org)
      gateway = AccessFixtures.gateway!(org)

      route =
        AccessRoute
        |> Ash.Changeset.for_create(
          :create,
          %{gateway_id: gateway.id, instance_id: instance.id, route_key: "8443"},
          authorize?: false
        )
        |> Ash.create!()

      [version] = versions!(AccessRoute.Version, route.id)

      assert version.version_action_type == :create
      assert is_nil(version.user_id)
      assert is_nil(version.actor_label)
    end

    test "an instance hostname's system mint versions with the nil actor" do
      user = AccountsFixtures.user!()
      instance = member_instance!(user)

      # Register is a member act behind the paid-once + funded pair,
      # and its certificate mint rides the platform kubeconfig seam —
      # stubbed like the register operation suite.
      {:ok, org} = FluxVale.Accounts.personal_org_for_user(user.id, authorize?: false)

      stub(K8s, :kubeconfig, fn -> {:ok, %{}} end)
      stub(Kubereq, :attach, fn req, _opts -> req end)
      stub(Kubereq, :apply, fn _req, _manifest, _fm -> {:ok, %{status: 201, body: %{}}} end)

      BillingFixtures.mark_paid!(org)
      BillingFixtures.funded_wallet!(org: org)

      domain =
        AccessDomain
        |> Ash.Changeset.for_create(:register, %{domain: "hostnames.example.test"}, actor: user)
        |> Ash.create!()

      hostname =
        InstanceHostname
        |> Ash.Changeset.for_create(
          :mint,
          %{instance_id: instance.id, access_domain_id: domain.id, label: "pt-host"},
          authorize?: false
        )
        |> Ash.create!()

      [version] = versions!(InstanceHostname.Version, hostname.id)

      assert version.version_action_name == :mint
      assert is_nil(version.user_id)
      assert is_nil(version.actor_label)
    end
  end
end
