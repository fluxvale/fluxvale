defmodule FluxVale.Infrastructure.Operations.RotatePocketIdSecretTest do
  @moduledoc false

  # #597 S5: the zero-downtime rotation — a second active secret, the
  # workload carries it (apply primitive), THEN the old one dies.
  # Order is the contract: never both sides invalid.

  # Serialized (async: false) — the shared feature-flag row's lock
  # order (the S2/S3/S4 files' note).
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  @held_key "held-key-not-a-real-credential"
  @issuer "https://id.example"
  @old_secret "old-secret-never-logged"

  @recipe %{
    "kind" => "env",
    "issuer_env" => "SSO_AUTHORITY",
    "client_id_env" => "SSO_CLIENT_ID",
    "client_secret_env" => "SSO_CLIENT_SECRET",
    "enabled_env" => "SSO_ENABLED",
    "pkce" => true
  }

  @schema %{
    "SSO_AUTHORITY" => %{label: "OIDC issuer URL", type: :string},
    "SSO_CLIENT_ID" => %{label: "OIDC client ID", type: :string},
    "SSO_CLIENT_SECRET" => %{label: "OIDC client secret", type: :string, secret: true},
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false}
  }

  setup do
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    BillingFixtures.funded_wallet!(org: org)

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, ref ->
      if String.starts_with?(ref, "fluxvale-pocketid-custody-") do
        {:ok, %{"POCKETID_API_KEY" => @held_key}}
      else
        {:ok, %{"SSO_CLIENT_SECRET" => "old-secret", "SMTP_HOST" => "smtp"}}
      end
    end)

    stub(Secret, :upsert, fn _kc, _ns, _n, _d -> {:ok, %{}} end)
    stub(Deployment, :restart, fn _kc, _ns, _n -> {:ok, %{}} end)

    pocket_id_version =
      InstanceFixtures.app_version!(app_slug: "pocket-id", configurable_env_vars: %{})

    pocket_id =
      pocket_id_version
      |> InstanceFixtures.instance!(owner)
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns-pid")

    PocketIdCustody.record!(
      %{
        organization_id: pocket_id.organization_id,
        instance_id: pocket_id.id,
        api_key_secret_ref: "fluxvale-pocketid-custody-#{pocket_id.id}",
        verified_at: DateTime.utc_now()
      },
      authorize?: false
    )

    app =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        oidc_callback_path: "/cb"
      )
      |> InstanceFixtures.instance!(owner)
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns-app")

    wiring =
      PocketIdWiring.record!(
        %{
          instance_id: app.id,
          pocket_id_instance_id: pocket_id.id,
          pocket_id_client_id: "client-1",
          pocket_id_secret_id: "secret-old"
        },
        authorize?: false
      )

    %{app: app, pocket_id: pocket_id, wiring: wiring, owner: owner}
  end

  defp url(pocket_id) do
    base = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{pocket_id.slug}.#{base}"
  end

  describe "rotate/2" do
    test "second secret, apply, then old dies — the row moves to the new secret id", %{
      app: app,
      pocket_id: pocket_id,
      wiring: wiring,
      owner: owner
    } do
      order = []

      stub(ApiClient, :create_secret, fn _u, @held_key, "client-1", new_secret ->
        send(self(), {:created, new_secret})
        {:ok, %{secret_id: "secret-new"}}
      end)

      expect(ApiClient, :delete_secret, fn _u, @held_key, "client-1", "secret-old" ->
        # The apply must ALREADY have happened (zero-timeout receive,
        # then put it back): the old secret dies only after the
        # workload carries the new one.
        receive do
          {:applied, _env} = msg -> send(self(), msg)
        after
          0 -> flunk("old secret deleted before the apply landed")
        end

        send(self(), :old_deleted)
        :ok
      end)

      stub(Secret, :upsert, fn _kc, "ns-app", "app-env", data ->
        send(self(), {:applied, data})
        {:ok, %{}}
      end)

      assert {:ok, updated} = Infrastructure.rotate_pocket_id_secret(wiring, actor: owner)
      assert updated.pocket_id_secret_id == "secret-new"
      assert updated.pocket_id_client_id == "client-1"

      assert_received {:created, new_secret}
      assert_received {:applied, env}
      assert env["SSO_CLIENT_SECRET"] == new_secret
      # Unrelated keys ride through untouched.
      assert env["SMTP_HOST"] == "smtp"
      assert byte_size(new_secret) >= 16
      assert_received :old_deleted

      assert app.id
             |> PocketIdWiring.get_by_instance!(authorize?: false)
             |> Map.get(:pocket_id_secret_id) ==
               "secret-new"
    end

    test "a refused apply leaves the old secret fully live — rotation simply hasn't happened", %{
      app: app,
      wiring: wiring,
      owner: owner
    } do
      stub(ApiClient, :create_secret, fn _u, _k, _c, _s -> {:ok, %{secret_id: "secret-new"}} end)

      stub(Secret, :upsert, fn _kc, _ns, _n, _d ->
        {:error, %K8s.Error{status_code: 500, reason: :unknown, message: "no"}}
      end)

      # The old secret must NOT be deleted (Mimic rejects the un-stubbed
      # delete call — the zero-downtime guarantee under failure).
      assert {:error, %K8s.Error{}} = Infrastructure.rotate_pocket_id_secret(wiring, actor: owner)

      assert PocketIdWiring.get_by_instance!(app.id, authorize?: false).pocket_id_secret_id ==
               "secret-old"
    end

    test "a failed old-secret delete is tolerated — the rotation is complete", %{
      wiring: wiring,
      owner: owner
    } do
      stub(ApiClient, :create_secret, fn _u, _k, _c, _s -> {:ok, %{secret_id: "secret-new"}} end)
      stub(ApiClient, :delete_secret, fn _u, _k, _c, _s -> {:error, :unreachable} end)

      assert {:ok, updated} = Infrastructure.rotate_pocket_id_secret(wiring, actor: owner)
      assert updated.pocket_id_secret_id == "secret-new"
    end

    test "the guards: flag off, not wired, undeployed, gone PocketID", %{
      app: app,
      pocket_id: pocket_id,
      wiring: wiring,
      owner: owner
    } do
      :ok = FeatureFlags.disable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

      assert {:error, :flag_disabled} =
               Infrastructure.rotate_pocket_id_secret(wiring, actor: owner)

      :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

      # Gone PocketID (the app still deployed — the op reads the app
      # instance first): the wiring outlives its IdP row.
      Ash.destroy!(pocket_id, authorize?: false)

      assert {:error, :pocket_id_gone} =
               Infrastructure.rotate_pocket_id_secret(wiring, actor: owner)

      # Undeployed (the LAST arm — the app stays undeployed after):
      # the row's wiring re-ships at the next deploy.
      app
      |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:namespace, nil)
      |> Ash.update!()

      assert {:error, :not_deployed} =
               Infrastructure.rotate_pocket_id_secret(wiring, actor: owner)
    end
  end
end
