defmodule FluxValeWeb.CatalogLive.DeployPocketIdOfferTest do
  @moduledoc false

  # #597 S3: the Pocket ID offer on the deploy wizard's configuration
  # step. Visibility is fail-closed (flag + recipe + an active Pocket
  # ID in the target org — otherwise NOTHING renders); the four card
  # states are each pinned; the offer's checkbox is unticked by
  # default (D7) and ticking hides exactly the recipe's manual env
  # inputs. The probe is Mimic-stubbed (the Tailscale ApiClient
  # stance) — no test ever talks to a live Pocket ID. The submit path
  # is S3-untouched: no test here deploys.
  # Sync: fabricates app rows with seeded slugs ("pocket-id"), which are
  # globally unique and shared with other modules doing the same. Sync
  # modules run alone, so the race cannot form (#669).

  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.PocketIdCustody
  alias FluxVale.Ops.FeatureFlags
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  # The deployed app's schema: the recipe's four SSO inputs (the
  # #529 manual fallback, from the Vaultwarden seed's shape) plus one
  # unrelated input that must survive a tick.
  @sso_specs %{
    "SSO_AUTHORITY" => %{label: "OIDC issuer URL", type: :string},
    "SSO_CLIENT_ID" => %{label: "OIDC client ID", type: :string},
    "SSO_CLIENT_SECRET" => %{label: "OIDC client secret", type: :string, secret: true},
    "SSO_ENABLED" => %{label: "Enable Pocket ID sign-in", type: :boolean, default: false}
  }

  @recipe %{
    "kind" => "env",
    "issuer_env" => "SSO_AUTHORITY",
    "client_id_env" => "SSO_CLIENT_ID",
    "client_secret_env" => "SSO_CLIENT_SECRET",
    "enabled_env" => "SSO_ENABLED",
    "pkce" => true
  }

  @schema Map.put(@sso_specs, "SMTP_HOST", %{label: "SMTP host", type: :string})

  setup %{conn: conn} do
    # The wizard's ladders are the seeded sizes (deploy_test's setup
    # note) — before the fixtures, same ordering caveat.
    :ok = FluxVale.Seeds.seed_pricing!()

    {user, conn} = SessionHelpers.user_with_session(conn)
    InstanceFixtures.local_cluster!()

    pocket_id_version =
      InstanceFixtures.app_version!(app_slug: "pocket-id", configurable_env_vars: %{})

    %{conn: conn, user: user, pocket_id_version: pocket_id_version}
  end

  # Tests enable the flag through the real verb (the ops surface),
  # never by minting a row — the fail-closed gate is part of what's
  # under test.
  defp flag_on! do
    :ok = FeatureFlags.enable(:pocketid_sso_wiring, actor: AccountsFixtures.platform_admin!())
  end

  defp sso_version!,
    do:
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        oidc_wiring: @recipe,
        published_at: DateTime.utc_now()
      )

  defp plain_version!,
    do:
      InstanceFixtures.app_version!(
        configurable_env_vars: @schema,
        published_at: DateTime.utc_now()
      )

  defp app_of!(version), do: Ash.load!(version, :app, authorize?: false).app

  # The active Pocket ID precondition (§4.1's shape: deployed, public,
  # running) plus custody (S2's row, built through the action).
  defp active_pocketid!(user, version, deployed_at) do
    instance = InstanceFixtures.instance!(version, user)
    running = InstanceFixtures.walk_to!(instance, :running)

    InstanceFixtures.pin!(running,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: deployed_at
    )
  end

  defp with_custody!(instance) do
    # S2's system funnel (their resource's writes are op-owned; the
    # bootstrap staging posture passes authorize?: false, their seed's
    # own stance).
    PocketIdCustody.record!(
      %{
        organization_id: instance.organization_id,
        instance_id: instance.id,
        api_key_secret_ref: "fluxvale-pocketid-#{instance.id}",
        verified_at: DateTime.utc_now()
      },
      authorize?: false
    )

    instance
  end

  defp pocketid_url(instance) do
    base_domain = Application.fetch_env!(:flux_vale, :instances_base_domain)
    "https://#{instance.slug}.#{base_domain}"
  end

  # Probe stubs. The wizard probes the custody-ready set newest
  # deployed first — mixed answers stub in that order.
  defp probe!(answer, n \\ 1) do
    expect(Req, :get, n, fn _url, _opts -> {:ok, %Req.Response{status: answer}} end)
  end

  defp probe_answers!([answer | rest]) do
    expect(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: answer}} end)
    if rest != [], do: probe_answers!(rest)
  end

  defp to_step_2(view, version) do
    view
    |> element("#version-#{version.id}")
    |> render_click()

    view
    |> element("button[phx-click='to-env']")
    |> render_click()
  end

  describe "visibility — fail-closed on all three gates" do
    test "nothing renders when the org has no active Pocket ID", %{conn: conn} do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)
      reject(Req, :get, 1)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      # No detection bleed, no probe fired — the empty org answer
      # short-circuits before any HTTP.
      refute has_element?(view, "#pocketid-offer")
      assert has_element?(view, "#env-form")
    end

    test "nothing renders while the flag is off — and no probe fires", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      version = sso_version!()
      app = app_of!(version)

      _pocketid =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      # No row: fail-closed means off in prod by absence — and off
      # means the wizard never touches the Pocket ID at all.
      reject(Req, :get, 1)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      refute has_element?(view, "#pocketid-offer")

      # A channel-level toggle against the absent card is silence.
      render_click(view, "toggle-pocketid", %{})

      refute has_element?(view, "#pocketid-offer")
      assert has_element?(view, "#env-SSO_AUTHORITY")
    end

    test "nothing renders for a version without an oidc_wiring recipe", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = plain_version!()
      app = app_of!(version)

      _pocketid =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      reject(Req, :get, 1)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      refute has_element?(view, "#pocketid-offer")
    end
  end

  describe "the four card states" do
    test "no custody: the one-time owner act, linked to the Pocket ID's page", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      pocketid = active_pocketid!(user, pocket_id_version, ~U[2026-01-01 00:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      assert has_element?(view, "#pocketid-no-custody")
      assert render(view) =~ "One-time: let FluxVale manage sign-in clients"

      assert has_element?(
               view,
               "[data-testid='pocketid-no-custody-link'][href='/instances/#{pocketid.id}']"
             )

      # Not the offer: no checkbox to tick.
      refute has_element?(view, "#pocketid-offer-check")
    end

    test "mid-setup (204): finish-setup copy, linked to the Pocket ID's page", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      pocketid =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      probe!(204)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      assert has_element?(view, "#pocketid-mid-setup")
      assert render(view) =~ "Finish setting up your Pocket ID first"

      assert has_element?(
               view,
               "[data-testid='pocketid-mid-setup-link'][href='/instances/#{pocketid.id}']"
             )

      refute has_element?(view, "#pocketid-offer-check")
    end

    test "offer: unticked checkbox, the URL and the named client in the copy", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      pocketid =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      probe!(404)

      {:ok, view, _mount_html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      html = render(view)

      assert has_element?(view, "#pocketid-offer-check")
      # D7: unticked by default — the checked attribute is absent.
      refute has_element?(view, "#pocketid-offer-check[checked]")

      # The copy names the URL and exactly what will happen.
      assert html =~ "Sign in with your Pocket ID — #{pocketid_url(pocketid)}"
      assert html =~ "creates a #{app.name} client named after this instance in your Pocket ID"

      # Manual inputs all present while unticked.
      for name <- ~w(SSO_AUTHORITY SSO_CLIENT_ID SSO_CLIENT_SECRET SSO_ENABLED SMTP_HOST) do
        assert has_element?(view, "#env-#{name}")
      end
    end

    test "unreachable: honest copy, the manual inputs right below", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      _pocketid =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      probe!(503)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      assert has_element?(view, "#pocketid-unreachable")
      assert render(view) =~ "Pocket ID not reachable right now"
      assert has_element?(view, "#env-SSO_AUTHORITY")
    end

    test "a completed Pocket ID still offers beside a mid-setup one", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      older_completed =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      _newer_mid_setup =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-02-01 00:00:00Z])
        |> with_custody!()

      # Probing is newest-deployed first: the newer one answers
      # mid-setup, the older one completed.
      probe_answers!([204, 404])

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      # A completed Pocket ID means the OFFER — the pickable set is
      # the completed ones only, so the mid-setup sibling is not
      # offered (no picker for a one-item set).
      assert has_element?(view, "#pocketid-offer-check")
      refute has_element?(view, "[data-testid='pocketid-picker']")

      label = render(element(view, "label[for='pocketid-offer-check']"))
      assert label =~ pocketid_url(older_completed)
    end

    test "nothing completed: mid-setup outranks unreachable", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      older_mid_setup =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      _newer_unreachable =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-02-01 00:00:00Z])
        |> with_custody!()

      probe_answers!([503, 204])

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      assert has_element?(view, "#pocketid-mid-setup")
      refute has_element?(view, "#pocketid-unreachable")

      assert has_element?(
               view,
               "[data-testid='pocketid-mid-setup-link'][href='/instances/#{older_mid_setup.id}']"
             )
    end
  end

  describe "the tick (D7 — default off, explicit on)" do
    setup %{conn: conn, user: user, pocket_id_version: pocket_id_version} do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      _pocketid =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      probe!(404)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      %{view: view}
    end

    test "ticking hides exactly the recipe's inputs; unticking restores them", %{view: view} do
      view
      |> element("#pocketid-offer-check")
      |> render_click()

      assert has_element?(view, "#pocketid-offer-check[checked]")
      assert has_element?(view, "#pocketid-offer-confirmed")

      for name <- ~w(SSO_AUTHORITY SSO_CLIENT_ID SSO_CLIENT_SECRET SSO_ENABLED) do
        refute has_element?(view, "#env-#{name}")
      end

      # Everything else stays.
      assert has_element?(view, "#env-SMTP_HOST")

      view
      |> element("#pocketid-offer-check")
      |> render_click()

      refute has_element?(view, "#pocketid-offer-check[checked]")
      refute has_element?(view, "#pocketid-offer-confirmed")
      assert has_element?(view, "#env-SSO_AUTHORITY")
      assert has_element?(view, "#env-SMTP_HOST")
    end

    test "a typed recipe value is dropped on tick — the platform owns those keys", %{view: view} do
      # Type a manual issuer, leave the step, come back — then tick.
      # The wizard state genuinely held the value before the tick.
      view
      |> element("#env-form")
      |> render_submit(%{env_values: %{"SSO_AUTHORITY" => "https://typed.example"}})

      view
      |> element("button[phx-click='back-env']")
      |> render_click()

      assert render(view) =~ "https://typed.example"

      view
      |> element("#pocketid-offer-check")
      |> render_click()

      # Hidden and gone from wizard state: a leftover typed value
      # riding the submit would contradict the platform-writes-them
      # posture (S4).
      assert has_element?(view, "#pocketid-offer-confirmed")
      refute render(view) =~ "https://typed.example"

      view
      |> element("#pocketid-offer-check")
      |> render_click()

      assert has_element?(view, "#env-SSO_AUTHORITY")
      refute render(view) =~ "https://typed.example"
    end
  end

  describe "multiple ready Pocket IDs" do
    setup %{conn: conn, user: user, pocket_id_version: pocket_id_version} do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      older =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      newer =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-02-01 00:00:00Z])
        |> with_custody!()

      probe!(404, 2)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      %{view: view, older: older, newer: newer}
    end

    test "the picker defaults to the most recently deployed", %{
      view: view,
      older: older,
      newer: newer
    } do
      assert has_element?(view, "[data-testid='pocketid-picker']")
      assert has_element?(view, "#pocketid-picker option[value='#{newer.id}'][selected]")

      # The copy (the checkbox's label) quotes the default's URL — the
      # other URL lives only in the picker's options.
      label = render(element(view, "label[for='pocketid-offer-check']"))
      assert label =~ pocketid_url(newer)
      refute label =~ pocketid_url(older)
    end

    test "picking moves the copy; a crafted id is silence", %{
      view: view,
      older: older,
      newer: newer
    } do
      view
      |> form("#pocketid-picker-form", pocketid_id: older.id)
      |> render_change()

      label = render(element(view, "label[for='pocketid-offer-check']"))
      assert label =~ pocketid_url(older)
      assert has_element?(view, "#pocketid-picker option[value='#{older.id}'][selected]")

      # The crafted id rides the raw channel event: the DOM's form
      # binding itself refuses a value no option offers (LiveViewTest's
      # form helper enforces the same), so only a hostile client
      # reaches this arm — the handler keeps the current pick.
      render_change(view, "pick-pocketid", %{"pocketid_id" => Ecto.UUID.generate()})

      # Unknown to the rendered options: the current pick stays.
      after_crafted = render(element(view, "label[for='pocketid-offer-check']"))
      assert after_crafted =~ pocketid_url(older)
      refute after_crafted =~ pocketid_url(newer)
    end
  end

  describe "the org context (#408)" do
    test "the offer follows the picked org", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      # The team org (and its active, custody-ready Pocket ID) exist
      # before the wizard opens — the band's picker lists mount-time
      # orgs, a real user's shape.
      {:ok, team} =
        FluxVale.Accounts.create_organization(user, %{
          name: "Offer Team",
          slug: "offer-team-#{System.unique_integer([:positive])}"
        })

      BillingFixtures.funded_wallet!(org: team)

      team_created =
        Instance.create!(
          %{
            name: "Team Pocket ID",
            app_version_id: pocket_id_version.id,
            organization_id: team.id,
            env_vars: %{}
          },
          actor: user
        )

      team_pocketid = InstanceFixtures.walk_to!(team_created, :running)

      InstanceFixtures.pin!(team_pocketid,
        namespace: "fluxvale-app-#{team_pocketid.id}",
        deployed_at: ~U[2026-04-01 00:00:00Z]
      )

      PocketIdCustody.record!(
        %{
          organization_id: team.id,
          instance_id: team_pocketid.id,
          api_key_secret_ref: "fluxvale-pocketid-#{team_pocketid.id}",
          verified_at: DateTime.utc_now()
        },
        authorize?: false
      )

      # Personal org: no Pocket ID — nothing renders.
      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      refute has_element?(view, "#pocketid-offer")

      # Pick the team org — the card appears without leaving step 2.
      probe!(404)

      render_change(view, "pick-org", %{"org_id" => team.id})

      assert has_element?(view, "#pocketid-offer-check")
      assert render(view) =~ pocketid_url(team_pocketid)
    end
  end

  describe "the probe's lifetime" do
    test "the answer caches for the wizard's life — a re-entry never re-asks", %{
      conn: conn,
      user: user,
      pocket_id_version: pocket_id_version
    } do
      flag_on!()
      version = sso_version!()
      app = app_of!(version)

      _pocketid =
        user
        |> active_pocketid!(pocket_id_version, ~U[2026-01-01 00:00:00Z])
        |> with_custody!()

      # Exactly one probe: the second step-2 entry would raise here if
      # it re-asked (Mimic's expect count is the assertion).
      probe!(404, 1)

      {:ok, view, _html} = live(conn, ~p"/apps/#{app.slug}/deploy")
      to_step_2(view, version)

      view
      |> element("button[phx-click='back-version']")
      |> render_click()

      to_step_2(view, version)

      assert has_element?(view, "#pocketid-offer-check")
    end
  end
end
