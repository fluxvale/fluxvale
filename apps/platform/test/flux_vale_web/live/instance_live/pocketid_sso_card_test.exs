defmodule FluxValeWeb.InstanceLive.PocketIdSsoCardTest do
  @moduledoc false

  # The SSO card on the app instance page (#597 §4.6, S5): the truth
  # shapes — wired (confirmation + Rotate/Disconnect), connect (the
  # retrofit), Pocket-ID-gone (clear wiring) — flag-gated, recipe-only.
  # The card's verbs ride the operations' own seams (stubbed here);
  # the op tests pin the discipline.

  # Serialized (async: false) — the shared feature-flag row's lock
  # order (the S2/S3/S4 files' note).
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import FluxVale.TestSupport.NoK8sLeaks
  import Phoenix.LiveViewTest

  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.Deployment
  alias FluxVale.Clients.K8s.Resources.Secret
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketId.ApiClient
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Infrastructure.PocketIdWiring
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @held_key "held-key-not-a-real-credential"
  @issuer "https://id.example"
  @minted_secret "minted-secret-never-logged"

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

  setup %{conn: conn} do
    InstanceFixtures.local_cluster!()
    {org, owner} = BillingFixtures.grant_free_org!()
    BillingFixtures.funded_wallet!(org: org)

    stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)

    stub(Secret, :get_data, fn _kc, _ns, ref ->
      if String.starts_with?(ref, "fluxvale-pocketid-custody-") do
        {:ok, %{"POCKETID_API_KEY" => @held_key}}
      else
        {:ok, %{}}
      end
    end)

    stub(Secret, :upsert, fn _kc, _ns, _n, _d -> {:ok, %{}} end)
    stub(Deployment, :restart, fn _kc, _ns, _n -> {:ok, %{}} end)

    conn = SessionHelpers.sign_in(conn, owner)

    %{conn: conn, org: org, owner: owner}
  end

  defp flag_on!,
    do: FeatureFlag.create!("pocketid_sso_wiring", %{enabled: true}, authorize?: false)

  defp pocket_id_version! do
    InstanceFixtures.app_version!(app_slug: "pocket-id", configurable_env_vars: %{})
  end

  defp pocket_id!(version, owner, slug) do
    version
    |> InstanceFixtures.instance!(owner)
    |> InstanceFixtures.walk_to!(:running)
    |> InstanceFixtures.pin!(namespace: "ns-#{slug}", slug: slug)
    |> tap(fn pocket_id ->
      PocketIdCustody.record!(
        %{
          organization_id: pocket_id.organization_id,
          instance_id: pocket_id.id,
          api_key_secret_ref: "fluxvale-pocketid-custody-#{pocket_id.id}",
          verified_at: DateTime.utc_now()
        },
        authorize?: false
      )
    end)
  end

  defp app!(owner) do
    version =
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        oidc_callback_path: "/cb"
      )

    version
    |> InstanceFixtures.instance!(owner)
    |> InstanceFixtures.walk_to!(:running)
    |> InstanceFixtures.pin!(namespace: "ns-app")
  end

  defp wire!(app, pocket_id) do
    PocketIdWiring.record!(
      %{
        instance_id: app.id,
        pocket_id_instance_id: pocket_id.id,
        pocket_id_client_id: "client-1",
        pocket_id_secret_id: "secret-1"
      },
      authorize?: false
    )
  end

  defp green_wiring!(pocket_id) do
    url = "https://#{pocket_id.slug}.#{host()}"
    stub(ApiClient, :get_discovery, fn ^url -> {:ok, @issuer} end)

    stub(ApiClient, :create_client, fn ^url, @held_key, _attrs ->
      {:ok, %{client_id: "pid-1", client_name: "n", secret_id: "sec-1", secret: @minted_secret}}
    end)
  end

  defp host, do: Application.fetch_env!(:flux_vale, :instances_base_domain)

  test "fail-closed: no flag row means no card, even wired", %{conn: conn, owner: owner} do
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    refute has_element?(view, "[data-testid=pocketid-sso-card]")
  end

  test "a recipe-less instance shows nothing even with the flag on", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    _pocket_id = pocket_id!(pid_version, owner, "pid")

    plain_version = InstanceFixtures.app_version!(configurable_env_vars: %{})
    plain = InstanceFixtures.instance!(plain_version, owner)

    {:ok, view, _html} = live(conn, ~p"/instances/#{plain.id}")

    refute has_element?(view, "[data-testid=pocketid-sso-card]")
  end

  test "wired: the confirmation names client and date, offers Rotate/Disconnect", %{
    conn: conn,
    owner: owner
  } do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    {:ok, view, html} = live(conn, ~p"/instances/#{app.id}")

    assert has_element?(view, "[data-testid=pocketid-sso-wired]")
    assert has_element?(view, "[data-testid=pocketid-rotate]")
    assert has_element?(view, "[data-testid=pocketid-disconnect]")
    assert html =~ "FluxVale · #{app.name}"
    assert html =~ "All Pocket ID users can sign in"
    refute has_element?(view, "#pocketid-connect-form")
    refute_k8s_terms(html)
  end

  test "connect: the retrofit offers the org's ready PocketIDs", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)

    {:ok, view, html} = live(conn, ~p"/instances/#{app.id}")

    assert has_element?(view, "[data-testid=pocketid-sso-connect-copy]")
    assert has_element?(view, "#pocketid-connect-form")
    assert has_element?(view, "[data-testid=pocketid-connect]")
    assert html =~ "own login keeps working"
  end

  test "connect submits the retrofit and lands the wired state", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    green_wiring!(pocket_id)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    view
    |> form("#pocketid-connect-form")
    |> render_submit()

    assert has_element?(view, "[data-testid=pocketid-sso-wired]")
    assert {:ok, wiring} = PocketIdWiring.get_by_instance(app.id, actor: owner)
    assert wiring.pocket_id_client_id == "pid-1"
  end

  # The select's pick must win over the hidden default (Plug takes the
  # LAST duplicate param) — the multi-PocketID regression pin.
  test "connect with several PocketIDs wires the SELECTED one, not the default", %{
    conn: conn,
    owner: owner
  } do
    flag_on!()
    pid_version = pocket_id_version!()
    # Created in order: the SECOND is the newest-deployed = the default
    # pick; the user selects the FIRST.
    first = pocket_id!(pid_version, owner, "pid-first")
    _second = pocket_id!(pid_version, owner, "pid-second")
    green_wiring!(first)
    app = app!(owner)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    assert has_element?(view, "select")

    view
    |> form("#pocketid-connect-form",
      pocket_id_instance_id: first.id
    )
    |> render_submit()

    assert {:ok, wiring} = PocketIdWiring.get_by_instance(app.id, actor: owner)
    assert wiring.pocket_id_instance_id == first.id
  end

  test "a refused connect renders in place, never a crash", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "sleepy")
    app = app!(owner)

    url = "https://#{pocket_id.slug}.#{host()}"
    stub(ApiClient, :get_discovery, fn ^url -> {:error, :unreachable} end)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    view
    |> form("#pocketid-connect-form")
    |> render_submit()

    assert has_element?(view, "[data-testid=pocketid-sso-error]")
    assert render(view) =~ "didn&#39;t answer"
    assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, actor: owner)
  end

  test "rotate rides the operation and stays wired", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    url = "https://#{pocket_id.slug}.#{host()}"

    stub(ApiClient, :create_secret, fn ^url, @held_key, "client-1", _s ->
      {:ok, %{secret_id: "secret-2"}}
    end)

    stub(ApiClient, :delete_secret, fn ^url, @held_key, "client-1", "secret-1" -> :ok end)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    view
    |> element("[data-testid=pocketid-rotate]")
    |> render_click()

    assert has_element?(view, "[data-testid=pocketid-sso-wired]")
    assert PocketIdWiring.get_by_instance!(app.id, actor: owner).pocket_id_secret_id == "secret-2"
  end

  test "disconnect clears the wiring and the card returns to connect", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    url = "https://#{pocket_id.slug}.#{host()}"
    stub(ApiClient, :delete_client, fn ^url, @held_key, "client-1" -> :ok end)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    view
    |> element("[data-testid=pocketid-disconnect]")
    |> render_click()

    assert has_element?(view, "[data-testid=pocketid-sso-connect-copy]")
    assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, actor: owner)
  end

  test "a refused client delete still disconnects — the copy names the leftover", %{
    conn: conn,
    owner: owner
  } do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    stub(ApiClient, :delete_client, fn _u, _k, _c -> {:error, :unreachable} end)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    html =
      view
      |> element("[data-testid=pocketid-disconnect]")
      |> render_click()

    assert html =~ "remains in your Pocket ID"
    assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, actor: owner)
  end

  test "the wiring outliving its PocketID renders the gone shape", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    # The PocketID dies while the wiring lives (§6): destroy its
    # custody first (the FK restricts), then the row.
    row = PocketIdCustody.get_by_instance!(pocket_id.id, authorize?: false)
    PocketIdCustody.revoke!(row, authorize?: false)

    Ash.destroy!(pocket_id, actor: owner)

    {:ok, view, html} = live(conn, ~p"/instances/#{app.id}")

    assert has_element?(view, "[data-testid=pocketid-sso-gone]")
    assert has_element?(view, "[data-testid=pocketid-clear-wiring]")
    assert html =~ "gone"
  end

  # Existence vs offer-readiness (§6's question is the ROW): revoking
  # custody makes the PocketID non-OFFERABLE but does not unwire the
  # standing wiring — the card stays truthful (WIRED), not gone.
  test "revoked custody keeps a live wiring WIRED — gone means the row died", %{
    conn: conn,
    owner: owner
  } do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    row = PocketIdCustody.get_by_instance!(pocket_id.id, authorize?: false)
    PocketIdCustody.revoke!(row, authorize?: false)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    assert has_element?(view, "[data-testid=pocketid-sso-wired]")
    refute has_element?(view, "[data-testid=pocketid-sso-gone]")
  end

  # A pre-deploy wiring's rotate refuses honestly at the OP (pinned in
  # the rotate op tests — :not_deployed); the card's error-render path
  # itself is pinned by the refused-connect test below.

  # Crafted verbs against a hidden card (nil wiring/state) are
  # silence — the handlers' nil arms.
  test "crafted rotate/disconnect events with no card standing are silence", %{
    conn: conn,
    owner: owner
  } do
    flag_on!()
    pid_version = pocket_id_version!()
    _pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)

    {:ok, view, html} = live(conn, ~p"/instances/#{app.id}")

    render_click(view, "pocketid-rotate", %{})
    render_click(view, "pocketid-disconnect", %{})
    render_click(view, "pocketid-connect", %{})

    # Still on the page, nothing created, nothing crashed.
    assert html =~ app.name
  end

  test "clearing a gone wiring restores the connect shape", %{conn: conn, owner: owner} do
    flag_on!()
    pid_version = pocket_id_version!()
    pocket_id = pocket_id!(pid_version, owner, "pid")
    app = app!(owner)
    wire!(app, pocket_id)

    # A SECOND PocketID keeps the org offer-ready after the clear.
    _replacement = pocket_id!(pid_version, owner, "pid-2")

    row = PocketIdCustody.get_by_instance!(pocket_id.id, authorize?: false)
    PocketIdCustody.revoke!(row, authorize?: false)

    Ash.destroy!(pocket_id, actor: owner)

    {:ok, view, _html} = live(conn, ~p"/instances/#{app.id}")

    html =
      view
      |> element("[data-testid=pocketid-clear-wiring]")
      |> render_click()

    # The gone-arm flash words ITS verb, not the client-delete notice.
    assert html =~ "Wiring cleared"
    assert has_element?(view, "[data-testid=pocketid-sso-connect-copy]")
    assert {:error, _none} = PocketIdWiring.get_by_instance(app.id, actor: owner)
  end
end
