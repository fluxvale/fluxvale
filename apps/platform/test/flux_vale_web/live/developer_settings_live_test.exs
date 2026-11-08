defmodule FluxValeWeb.DeveloperSettingsLiveTest do
  @moduledoc false

  # The developer settings page (#635): the Device sign-ins (#362 T3)
  # and API tokens (#483) sections, MOVED from /settings/access — the
  # flows ride the new mount, everything else about them unchanged.

  use FluxValeWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Api.Scopes
  alias FluxVale.Identity
  alias FluxVale.Identity.DeviceCode
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    user = AccountsFixtures.user!()

    {:ok, conn: SessionHelpers.sign_in(conn, user), user: user}
  end

  # -- The frame ----------------------------------------------------------

  describe "the page and its navigation" do
    test "renders both sections in the account frame, Developer current in the sidebar", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert view.module == FluxValeWeb.DeveloperSettingsLive

      # The account frame, not the org one: back to settings, the
      # settings title, and NO org identity or org tabs.
      assert has_element?(view, "[data-testid='settings-title']", "Account settings")
      assert has_element?(view, "[data-testid='settings-developer-back'][href='/settings']")
      assert has_element?(view, "[data-testid='developer-heading']", "Developer")
      refute has_element?(view, "[data-testid='org-settings-tabs']")
      refute has_element?(view, "[data-testid='org-name']")

      assert has_element?(view, "[data-testid='account-settings-sidebar']")

      developer = render(element(view, "[data-testid='account-settings-nav-developer']"))
      assert developer =~ ~s(aria-current="page")
      assert developer =~ ~s(href="/settings/developer")

      for key <- ["profile", "access", "wallet"] do
        quiet = render(element(view, "[data-testid='account-settings-nav-#{key}']"))
        refute quiet =~ "aria-current", "#{key} should stay quiet"
      end
    end

    test "the page is actor-scoped: it renders without a personal org", %{conn: conn, user: user} do
      # The access surface degrades to not-found for the seeded/legacy
      # no-org actor; the developer page needs no org, so it stays. The
      # sidebar mirrors the shape: Profile and Developer only (#635's
      # ungated entry). Destroying the owner membership is the
      # sanctioned posture to reach the shape (OrgSwitcherTest's).
      membership =
        Membership
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.filter(user_id == ^user.id and role == :owner)
        |> Ash.read_one!(authorize?: false)

      Ash.destroy!(membership, authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert has_element?(view, "[data-testid='device-sign-ins']")
      assert has_element?(view, "[data-testid='api-tokens']")

      assert has_element?(view, "[data-testid='account-settings-nav-profile']")
      assert has_element?(view, "[data-testid='account-settings-nav-developer']")
      refute has_element?(view, "[data-testid='account-settings-nav-access']")
      refute has_element?(view, "[data-testid='account-settings-nav-wallet']")
    end

    test "the gateway panel did not come along — no access surface here", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      refute has_element?(view, "[data-testid='access-empty']")
      refute has_element?(view, "[data-testid='access-gateway-card']")
      refute has_element?(view, "#access-enable-form")
    end

    test "an anonymous visit redirects to sign-in with the return path" do
      # #462: the redirect carries the return path back to the page
      assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/settings/developer")

      assert to == "/sign-in?return_to=%2Fsettings%2Fdeveloper"
    end
  end

  # ---- Device sign-ins (#362 T3): the approval surface ------------------

  describe "the device sign-ins section" do
    test "the section renders with its empty line when nothing is pending", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert has_element?(view, "[data-testid='device-sign-ins']")
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")
      assert has_element?(view, "#device-sign-ins")
      refute has_element?(view, "[data-testid='device-sign-in-row']")
    end

    test "a pending sign-in renders its user_code, scopes, client and expiry", %{
      conn: conn
    } do
      {:ok, _row} =
        Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: ["instances:read"]})

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      row_html = render(element(view, "[data-testid='device-sign-in-row']"))
      assert row_html =~ ~r/[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}/
      assert has_element?(view, "[data-testid='device-user-code']")
      assert has_element?(view, "[data-testid='device-meta']")

      meta = render(element(view, "[data-testid='device-meta']"))
      assert meta =~ "instances:read"
      assert meta =~ "client fluxvale-cli"
      assert meta =~ "expires in"

      assert has_element?(view, "[data-testid='device-approve']")
      assert has_element?(view, "[data-testid='device-deny']")
      refute has_element?(view, "[data-testid='device-sign-ins-empty']")
    end

    test "empty scopes render as full access (OQ #9's first-party shape)", %{
      conn: conn
    } do
      {:ok, _row} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert render(element(view, "[data-testid='device-meta']")) =~ "all scopes (full access)"
    end

    test "approving binds the row to the clicking user — the poll then mints for them", %{
      conn: conn,
      user: user
    } do
      {:ok, row} =
        Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: ["wallet:read"]})

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      view
      |> element("[data-testid='device-approve']")
      |> render_click()

      # The row approved with the actor as the approver.
      {:ok, approved_row} = DeviceCode.get_by_device_code(row.device_code, authorize?: false)
      assert approved_row.status == :approved
      assert approved_row.user_id == user.id

      # The list refreshes (the row leaves pending).
      refute has_element?(view, "[data-testid='device-sign-in-row']")
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")

      # The next poll mints the PAT FOR the clicking user.
      assert {:ok, %{pat: pat}} =
               Identity.poll_device_code("fluxvale-cli", approved_row.device_code)

      assert pat.user_id == user.id
    end

    test "denying the sign-in leaves the row denied", %{conn: conn} do
      {:ok, minted} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      view
      |> element("[data-testid='device-deny']")
      |> render_click()

      {:ok, denied_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert denied_row.status == :denied
      assert denied_row.user_id == nil

      refute has_element?(view, "[data-testid='device-sign-in-row']")
    end

    test "a stale click (the row handled between render and click) converges without crashing", %{
      conn: conn,
      user: user
    } do
      {:ok, minted} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      # The row leaves pending underneath the panel.
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _denied} = DeviceCode.deny(pending_row, actor: user)

      view
      |> element("[data-testid='device-approve']")
      |> render_click()

      # The stale-view answer: the list refetched, no crash.
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")
      {:ok, after_click} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert after_click.status == :denied
    end

    test "a stale DENY click (the row handled between render and click) converges too", %{
      conn: conn,
      user: user
    } do
      {:ok, minted} = Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: []})

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      # The row leaves pending underneath the panel (another tab won).
      {:ok, pending_row} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      {:ok, _approved} = DeviceCode.approve(pending_row, actor: user)

      view
      |> element("[data-testid='device-deny']")
      |> render_click()

      # The deny was a no-op — the row stays approved (the approve won).
      assert has_element?(view, "[data-testid='device-sign-ins-empty']")
      {:ok, after_click} = DeviceCode.get_by_device_code(minted.device_code, authorize?: false)
      assert after_click.status == :approved
      assert after_click.user_id == user.id
    end
  end

  # ---- API tokens (#483): create, list, revoke the actor's own PATs -----

  describe "the API tokens section" do
    test "the section renders with the create form, the catalog scopes and the empty line", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert has_element?(view, "[data-testid='api-tokens']")
      assert has_element?(view, "#api-token-form-0")
      assert has_element?(view, "[data-testid='api-token-name-input']")
      assert has_element?(view, "[data-testid='api-token-create']")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
      assert has_element?(view, "#api-token-rows")
      refute has_element?(view, "[data-testid='api-token-row']")
      refute has_element?(view, "[data-testid='api-token-reveal']")
    end

    test "the scope checkboxes render exactly the existing catalog, not a new mechanism", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      section_html = render(element(view, "[data-testid='api-tokens']"))
      doc = LazyHTML.from_fragment(section_html)

      values =
        doc
        |> LazyHTML.query("input[data-testid='api-token-scope']")
        |> LazyHTML.attribute("value")

      assert Enum.sort(values) == Enum.sort(Scopes.all_scopes())

      # The labels ride the same strings (a catalog addition labels itself).
      section = render(element(view, "[data-testid='api-tokens']"))
      assert section =~ "instances:read"
      assert section =~ "Instances, read only"
      assert section =~ "instances:write"
      assert section =~ "Instances, manage (includes read)"
    end

    test "creating a token shows the raw once, stores hash-only, and never logs it", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      log =
        capture_log(fn ->
          view
          |> form("#api-token-form-0", %{
            token: %{name: "ci deploys", scopes: ["instances:read", "wallet:read"]}
          })
          |> render_submit()
        end)

      # The raw value exists on the page (the reveal) and nowhere else:
      # not in the logs.
      refute log =~ "fvpat_"

      assert has_element?(view, "[data-testid='api-token-reveal']")
      reveal = render(element(view, "[data-testid='api-token-reveal']"))
      assert reveal =~ "only time the full token is shown"
      assert has_element?(view, "[data-testid='api-token-reveal-copy']")
      assert has_element?(view, "[data-testid='api-token-reveal-done']")

      html = render(view)
      assert [raw] = Regex.run(~r/fvpat_[A-Za-z0-9_-]{43}/, html)

      # The page renders the raw exactly where the reveal needs it: the
      # code line the user reads and the copy button's payload. Nothing
      # else on the page carries it (the copy hook's data attribute is
      # the second rendering — both are the reveal's own nodes).
      occurrences = Regex.scan(~r/fvpat_[A-Za-z0-9_-]{43}/, html)
      assert length(occurrences) == 2
      refute render(element(view, "#api-token-rows")) =~ raw

      # Hash-only storage: the row answers to the digest of the shown
      # value and carries nothing that reproduces it.
      digest = PersonalAccessToken.token_hash(raw)

      assert {:ok, row} = PersonalAccessToken.get_by_token_hash(digest, authorize?: false)
      assert row.token_hash == digest
      assert row.token_hash != raw
      assert row.user_id == user.id
      assert row.name == "ci deploys"
      assert row.scopes == ["instances:read", "wallet:read"]

      # The list refreshed with the new row.
      row_html = render(element(view, "[data-testid='api-token-row']"))
      assert row_html =~ "ci deploys"
      refute row_html =~ raw

      # The submission is disarmed: the form re-keyed (a changed id
      # replaces the subtree, clearing the dirty input a value patch
      # cannot reach), so a second click cannot mint a duplicate.
      refute has_element?(view, "#api-token-form-0")
      assert has_element?(view, "#api-token-form-1")

      # Dismissal is the end of the raw value's life: nothing renders
      # or holds it afterwards.
      view
      |> element("[data-testid='api-token-reveal-done']")
      |> render_click()

      refute has_element?(view, "[data-testid='api-token-reveal']")
      refute render(view) =~ raw
    end

    test "no scopes selected mints an identity-only token", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      view
      |> form("#api-token-form-0", %{token: %{name: "me only"}})
      |> render_submit()

      meta = render(element(view, "[data-testid='api-token-meta']"))
      assert meta =~ "no scopes (identity only)"

      assert {:ok, [row]} = PersonalAccessToken.list_for_user(user.id, authorize?: false)
      assert row.scopes == []
      assert row.name == "me only"
      assert row.user_id == user.id
    end

    test "the list is newest first when several tokens exist", %{conn: conn, user: user} do
      mint_token!(user, "first", [])
      mint_token!(user, "second", [])

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      rows_html = render(element(view, "#api-token-rows"))
      doc = LazyHTML.from_fragment(rows_html)

      names =
        doc
        |> LazyHTML.query("[data-testid='api-token-name']")
        |> Enum.map(fn node ->
          name = LazyHTML.text(node)
          String.trim(name)
        end)

      assert names == ["second", "first"]
    end

    test "same-instant rows tie-break by id and the comparator orders mixed inserts", %{
      conn: conn,
      user: user
    } do
      # Pinned created_at values are write-time stamps the mint cannot
      # set — the sanctioned Ash.Seed exception. Newest inserted first,
      # two rows sharing an instant: the sort then exercises every arm
      # (the :gt on the newer pair, the :eq tiebreak on the equal pair)
      # that ascending back-to-back mints can never reach.
      now = DateTime.utc_now()
      second_precision_now = DateTime.truncate(now, :second)
      future = DateTime.add(second_precision_now, 365 * 24 * 60 * 60, :second)

      base = %{
        user_id: user.id,
        scopes: [],
        expires_at: future,
        metadata: %{},
        last_used_at: nil,
        revoked_at: nil
      }

      Ash.Seed.seed!(
        PersonalAccessToken,
        Map.merge(base, %{
          name: "newest",
          token_hash: PersonalAccessToken.token_hash("seed-newest"),
          created_at: DateTime.add(second_precision_now, 60, :second),
          updated_at: DateTime.add(second_precision_now, 60, :second)
        })
      )

      Ash.Seed.seed!(
        PersonalAccessToken,
        Map.merge(base, %{
          name: "tie-a",
          token_hash: PersonalAccessToken.token_hash("seed-tie-a"),
          created_at: second_precision_now,
          updated_at: second_precision_now
        })
      )

      Ash.Seed.seed!(
        PersonalAccessToken,
        Map.merge(base, %{
          name: "tie-b",
          token_hash: PersonalAccessToken.token_hash("seed-tie-b"),
          created_at: second_precision_now,
          updated_at: second_precision_now
        })
      )

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      rows_html = render(element(view, "#api-token-rows"))
      doc = LazyHTML.from_fragment(rows_html)

      names =
        doc
        |> LazyHTML.query("[data-testid='api-token-name']")
        |> Enum.map(fn node ->
          name = LazyHTML.text(node)
          String.trim(name)
        end)

      # "newest" is the chronologically latest row. "tie-a" and
      # "tie-b" share an instant: the later insert carries the bigger
      # uuid_v7 and renders first.
      assert names == ["newest", "tie-b", "tie-a"]
    end

    test "a listed token renders its metadata: scopes, created, last used, expiry", %{
      conn: conn,
      user: user
    } do
      pat = mint_token!(user, "terraform", ["gateways:read"])

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      row = render(element(view, "[data-testid='api-token-row']"))
      assert row =~ "terraform"
      assert row =~ "gateways:read"
      assert row =~ "Created"
      assert row =~ "Never used"
      assert row =~ "Expires"
      assert row =~ Calendar.strftime(pat.expires_at, "%b %d, %Y")
      assert has_element?(view, "[data-testid='api-token-status-active']")
      assert has_element?(view, "[data-testid='api-token-revoke']")
    end

    test "a token the API has been used with shows its last-used date", %{
      conn: conn,
      user: user
    } do
      pat = mint_token!(user, "used", [])

      # The auth path's system write (the plug's touch posture) — no
      # actor-facing surface stamps last-used.
      assert {:ok, _stamped} = PersonalAccessToken.touch_last_used(pat, authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert render(element(view, "[data-testid='api-token-meta']")) =~ "Last used"
    end

    test "an expired token shows the Expired badge and no revoke affordance", %{
      conn: conn,
      user: user
    } do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, %{pat: _pat}} =
        Identity.mint_pat(user, %{user_id: user.id, name: "stale", scopes: [], expires_at: past})

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert has_element?(view, "[data-testid='api-token-status-expired']")
      assert render(element(view, "[data-testid='api-token-row']")) =~ "stale"
      refute has_element?(view, "[data-testid='api-token-revoke']")
    end

    test "revoke is confirm-armed: a crafted click is a no-op, cancel disarms, confirm severs", %{
      conn: conn,
      user: user
    } do
      pat = mint_token!(user, "ci", ["wallet:read"])

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      # Un-armed: the crafted revoke is a no-op, the row stays live.
      render_click(view, "revoke-token", %{"id" => pat.id})
      assert {:ok, row} = PersonalAccessToken.get(pat.id, authorize?: false)
      assert row.revoked_at == nil

      # Arm: the confirm callout replaces the button; cancel disarms.
      view
      |> element("[data-testid='api-token-revoke']")
      |> render_click()

      assert has_element?(view, "[data-testid='api-token-revoke-confirm']")
      refute has_element?(view, "[data-testid='api-token-revoke']")

      view
      |> element("[data-testid='api-token-revoke-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='api-token-revoke-confirm']")
      assert has_element?(view, "[data-testid='api-token-revoke']")

      # Arm again and confirm: the sever is immediate.
      view
      |> element("[data-testid='api-token-revoke']")
      |> render_click()

      view
      |> element("[data-testid='api-token-revoke-confirm-button']")
      |> render_click()

      assert has_element?(
               view,
               "#flash-info",
               "Token revoked. Anything using it stops working now."
             )

      assert has_element?(view, "[data-testid='api-token-status-revoked']")
      refute has_element?(view, "[data-testid='api-token-revoke']")

      assert {:ok, severed} = PersonalAccessToken.get(pat.id, authorize?: false)
      refute severed.revoked_at == nil
    end

    test "the page is self-service: another user's token is neither listed nor revocable", %{
      conn: conn,
      user: user
    } do
      pat = mint_token!(user, "owner only", ["catalog:read"])
      intruder = AccountsFixtures.user!()

      {:ok, view, _html} = live(SessionHelpers.sign_in(conn, intruder), ~p"/settings/developer")

      refute render(view) =~ "owner only"
      assert has_element?(view, "[data-testid='api-tokens-empty']")

      # Forged ids arm and revoke — the operation's owner-gated lookup
      # is what refuses, the flash is the honest line.
      render_click(view, "arm-token-revoke", %{"id" => pat.id})
      render_click(view, "revoke-token", %{"id" => pat.id})

      assert has_element?(
               view,
               "#flash-error",
               "Couldn't revoke the token. Refresh and try again."
             )

      assert {:ok, still_live} = PersonalAccessToken.get(pat.id, authorize?: false)
      assert still_live.revoked_at == nil
    end

    test "a device-flow token shows in the list with its provenance and revokes like any other",
         %{
           conn: conn,
           user: user
         } do
      {:ok, row} =
        Identity.mint_device_code(%{client_id: "fluxvale-cli", scopes: ["instances:read"]})

      {:ok, approved} = DeviceCode.approve(row, actor: user)

      assert {:ok, %{pat: pat}} =
               Identity.poll_device_code("fluxvale-cli", approved.device_code)

      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      token_row = render(element(view, "[data-testid='api-token-row']"))
      assert token_row =~ "CLI sign-in"
      assert token_row =~ "instances:read"
      assert has_element?(view, "[data-testid='api-token-provenance']")

      view
      |> element("[data-testid='api-token-revoke']")
      |> render_click()

      view
      |> element("[data-testid='api-token-revoke-confirm-button']")
      |> render_click()

      assert {:ok, severed} = PersonalAccessToken.get(pat.id, authorize?: false)
      refute severed.revoked_at == nil
    end

    test "an empty name is refused and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      view
      |> form("#api-token-form-0", %{token: %{name: "   "}})
      |> render_submit()

      assert has_element?(view, "#flash-error", "Give the token a name first.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")

      # The failed submit kept the form key (the re-key is the success
      # path's disarm — a failure leaves the typed name standing).
      assert has_element?(view, "#api-token-form-0")
      refute has_element?(view, "#api-token-form-1")
    end

    test "a name past the 100-character limit is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      view
      |> form("#api-token-form-0", %{token: %{name: String.duplicate("a", 101)}})
      |> render_submit()

      assert has_element?(
               view,
               "#flash-error",
               "Couldn't create the token. Check the name and try again."
             )

      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "a crafted off-catalog scope is refused by the domain", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "scopes" => ["wallet:write"]}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "a crafted duplicate scope is refused by the domain too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "scopes" => ["wallet:read", "wallet:read"]}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "crafted wrong-typed payloads are no-ops, never crashes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      # A non-map token payload and a non-binary name land the
      # empty-name refusal; a non-binary revoke id falls through the
      # binary-guarded head to the no-op. None of them crash.
      assert render_click(view, "create-token", %{"token" => "junk"}) =~ "API tokens"

      assert render_click(view, "create-token", %{"token" => %{"name" => ["a", "b"]}}) =~
               "API tokens"

      assert render_click(view, "arm-token-revoke", %{"id" => 123}) =~ "API tokens"
      assert render_click(view, "revoke-token", %{"id" => 123}) =~ "API tokens"

      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "crafted events without payloads are no-ops, never crashes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert render_click(view, "create-token", %{}) =~ "API tokens"
      assert render_click(view, "arm-token-revoke", %{}) =~ "API tokens"
      assert render_click(view, "revoke-token", %{}) =~ "API tokens"
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end
  end

  # ---- API tokens (#483) helpers ----

  # Self-mint through the operation — the same seam the panel rides,
  # so every precondition the tests assert against is action-built.
  defp mint_token!(user, name, scopes) do
    {:ok, %{pat: pat}} = Identity.mint_pat(user, %{user_id: user.id, name: name, scopes: scopes})
    pat
  end
end
