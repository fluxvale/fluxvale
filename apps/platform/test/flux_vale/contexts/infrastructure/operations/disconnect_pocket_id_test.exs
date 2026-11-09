defmodule FluxVale.Infrastructure.Operations.DisconnectPocketIdTest do
  @moduledoc false

  # #597 S5: the disconnect — best-effort client delete (D6: refused
  # never blocks), strip the recipe's env from row AND workload, clear
  # the wiring. The app keeps its local login.

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
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false},
    "SMTP_HOST" => %{label: "SMTP host", type: :string}
  }

  setup do
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())

    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    BillingFixtures.funded_wallet!(org: org)

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, ref ->
      case ref do
        "fluxvale-pocketid-custody-" <> _suffix -> {:ok, %{"POCKETID_API_KEY" => @held_key}}
        "app-env" -> {:ok, %{"SSO_AUTHORITY" => @issuer, "SMTP_HOST" => "smtp"}}
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

    app_version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        oidc_callback_path: "/cb"
      )

    created =
      Instance.create!(
        %{
          name: "Inst #{System.unique_integer()}",
          app_version_id: app_version.id,
          env_vars: %{"SMTP_HOST" => "smtp"}
        },
        actor: owner
      )

    app =
      created
      |> InstanceFixtures.walk_to!(:running)
      |> InstanceFixtures.pin!(namespace: "ns-app")

    PocketIdWiring.record!(
      %{
        instance_id: app.id,
        pocket_id_instance_id: pocket_id.id,
        pocket_id_client_id: "client-1",
        pocket_id_secret_id: "secret-1"
      },
      authorize?: false
    )

    %{app: app, pocket_id: pocket_id, owner: owner}
  end

  defp url(pocket_id) do
    base = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{pocket_id.slug}.#{base}"
  end

  describe "disconnect/2" do
    test "deletes the client, strips row + workload, clears the wiring", %{
      app: app,
      pocket_id: pocket_id,
      owner: owner
    } do
      expect(ApiClient, :delete_client, fn _u, @held_key, "client-1" ->
        send(self(), :client_deleted)
        :ok
      end)

      expect(Secret, :upsert, fn _kc, "ns-app", "app-env", data ->
        send(self(), {:stripped, data})
        {:ok, %{}}
      end)

      expect(Deployment, :restart, fn _kc, "ns-app", "app" -> {:ok, %{}} end)

      assert {:ok, %{client_deleted: true}} =
               Infrastructure.disconnect_pocket_id(app, actor: owner)

      assert_received :client_deleted
      assert_received {:stripped, data}
      # The recipe's keys are GONE (unset semantics), user env intact.
      assert data == %{"SMTP_HOST" => "smtp"}

      reloaded = Instance.get_by_id!(app.id, actor: owner)
      assert reloaded.env_vars == %{"SMTP_HOST" => "smtp"}
      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "a refused client delete does not block — the notice carries it", %{
      app: app,
      owner: owner
    } do
      stub(ApiClient, :delete_client, fn _u, _k, _c -> {:error, :unreachable} end)

      assert {:ok, %{client_deleted: false}} =
               Infrastructure.disconnect_pocket_id(app, actor: owner)

      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
    end

    test "not-wired is the honest refusal; flag-off likewise", %{app: app, owner: owner} do
      wiring = PocketIdWiring.get_by_instance!(app.id, authorize?: false)
      PocketIdWiring.replace(wiring, authorize?: false)

      assert {:error, :not_wired} = Infrastructure.disconnect_pocket_id(app, actor: owner)
    end

    # The §6 gone shape: the PocketID row is gone, so no client is
    # reachable — the strip + clear still happen (the card's Clear
    # wiring verb).
    test "a gone PocketID clears the wiring without a client delete", %{
      app: app,
      pocket_id: pocket_id,
      owner: owner
    } do
      custody_row = PocketIdCustody.get_by_instance!(pocket_id.id, authorize?: false)
      PocketIdCustody.revoke!(custody_row, authorize?: false)

      Ash.destroy!(pocket_id, authorize?: false)

      assert {:ok, %{client_deleted: false}} =
               Infrastructure.disconnect_pocket_id(app, actor: owner)

      assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, authorize?: false)
      assert Instance.get_by_id!(app.id, actor: owner).env_vars == %{"SMTP_HOST" => "smtp"}
    end
  end
end
