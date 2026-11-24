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

  # #484 W5: the quickstart is ONE click from the mint — the link
  # renders INSIDE the API tokens section (the scoped selector is the
  # claim), riding the section's move from /settings/access (#638).
  test "the tokens section links the agent quickstart one click away", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/developer")

    assert has_element?(view, "#api-tokens [data-testid='api-tokens-agents-link']")

    link = render(element(view, "[data-testid='api-tokens-agents-link']"))
    assert link =~ ~s(href="/settings/agents")
    assert link =~ "AI agent"
  end

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

    test "both section anchors keep their ids on the new page", %{conn: conn} do
      # The device flow's landing and any verification_uri_complete-style
      # deep link target these ids; they moved WITH the sections.
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert has_element?(view, "#device-sign-ins")
      assert has_element?(view, "#api-tokens")
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
    test "the section renders with the create form, the grouped scope picker and the empty line",
         %{
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

    test "the grouped picker renders all six domains in catalog order with the right options", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      groups_html = render(element(view, "[data-testid='api-token-scope-groups']"))
      doc = LazyHTML.from_fragment(groups_html)

      domains =
        doc
        |> LazyHTML.query("[data-testid^='api-token-scope-group-']")
        |> LazyHTML.attribute("data-domain")

      assert domains == ["instances", "backups", "gateways", "wallet", "catalog", "organizations"]

      # Writable domains: three equal columns, all three options, no
      # Read-only tag, and exactly the "none" radio checked.
      for key <- ["instances", "backups", "gateways", "organizations"] do
        group = render(element(view, "[data-testid='api-token-scope-group-#{key}']"))
        group_doc = LazyHTML.from_fragment(group)

        assert group =~ "grid-cols-3"
        refute group =~ "grid-cols-2"
        refute group =~ "Read-only"

        for level <- ["none", "read", "write"] do
          assert has_element?(view, "[data-testid='api-token-scope-#{key}-#{level}']")
        end

        radios = LazyHTML.query(group_doc, "input[type='radio']")
        values = LazyHTML.attribute(radios, "value")
        assert Enum.sort(values) == ["none", "read", "write"]

        checked =
          group_doc
          |> LazyHTML.query("input[type='radio'][checked]")
          |> LazyHTML.attribute("value")

        assert checked == ["none"]
      end

      # Read-only domains: the narrower two-column track (so No access
      # and Read line up with the writable rows), no write option, the
      # Read-only tag, and the one-line reason in the detail.
      for key <- ["wallet", "catalog"] do
        group = render(element(view, "[data-testid='api-token-scope-group-#{key}']"))
        group_doc = LazyHTML.from_fragment(group)

        assert group =~ "grid-cols-2"
        assert has_element?(view, "[data-testid='api-token-scope-#{key}-none']")
        assert has_element?(view, "[data-testid='api-token-scope-#{key}-read']")
        refute has_element?(view, "[data-testid='api-token-scope-#{key}-write']")
        assert has_element?(view, "[data-testid='api-token-scope-readonly-#{key}']")
        assert group =~ "Read-only"

        radios = LazyHTML.query(group_doc, "input[type='radio']")
        values = LazyHTML.attribute(radios, "value")
        assert Enum.sort(values) == ["none", "read"]

        detail = render(element(view, "[data-testid='api-token-scope-detail-#{key}']"))
        assert detail =~ "No write scope exists for this domain."
      end

      # Everything starts at No access and the summary says what that mints.
      for key <- ["instances", "backups", "gateways", "wallet", "catalog", "organizations"] do
        assert has_element?(
                 view,
                 "[data-testid='api-token-scope-group-#{key}'][data-level='none']"
               )
      end

      summary = render(element(view, "[data-testid='api-token-scope-summary']"))
      assert summary =~ "No scopes selected."
      assert summary =~ "can only identify itself"
    end

    test "each option label carries the keyboard focus outline (the radios are sr-only)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      for level <- ["none", "read", "write"] do
        label = render(element(view, "[data-testid='api-token-scope-instances-#{level}']"))
        assert label =~ "has-[:focus-visible]:outline-focus"
      end
    end

    test "selecting Read renders the domain's scope copy and updates the summary", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"backups" => "read"}}
      })

      assert has_element?(
               view,
               "[data-testid='api-token-scope-group-backups'][data-level='read']"
             )

      assert has_element?(
               view,
               "[data-testid='api-token-scope-backups-read'][data-included='false']"
             )

      detail = render(element(view, "[data-testid='api-token-scope-detail-backups']"))
      assert detail =~ "backups:read"
      assert detail =~ Scopes.describe("backups:read")
      refute detail =~ "backups:write"

      summary = render(element(view, "[data-testid='api-token-scope-summary']"))
      assert summary =~ "Minted scopes (1):"
      assert summary =~ "backups:read"
      refute summary =~ "No scopes selected."
    end

    test "selecting Write includes Read, renders both scopes' copy and lists both in the summary",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_change(view, "scope-change", %{
        "token" => %{"name" => "ci deploys", "domain_levels" => %{"instances" => "write"}}
      })

      assert has_element?(
               view,
               "[data-testid='api-token-scope-group-instances'][data-level='write']"
             )

      read_option = render(element(view, "[data-testid='api-token-scope-instances-read']"))
      assert read_option =~ ~s(data-included="true")
      assert read_option =~ "✓ Read"

      detail = render(element(view, "[data-testid='api-token-scope-detail-instances']"))
      assert detail =~ "instances:read"
      assert detail =~ Scopes.describe("instances:read")
      assert detail =~ "(included)"
      assert detail =~ "instances:write"
      assert detail =~ Scopes.describe("instances:write")

      summary = render(element(view, "[data-testid='api-token-scope-summary']"))
      assert summary =~ "Minted scopes (2):"
      assert summary =~ "instances:read"
      assert summary =~ "instances:write"

      # The typed name rode the change event into the form's source
      # data, so the re-render keeps it in the input's value.
      assert render(element(view, "[data-testid='api-token-name-input']")) =~
               ~s(value="ci deploys")
    end

    test "switching back to No access clears the domain from the summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      # A read-only domain's Read first: its detail rides the same branches.
      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"wallet" => "read"}}
      })

      assert has_element?(view, "[data-testid='api-token-scope-group-wallet'][data-level='read']")

      wallet_detail = render(element(view, "[data-testid='api-token-scope-detail-wallet']"))
      assert wallet_detail =~ "wallet:read"
      assert wallet_detail =~ Scopes.describe("wallet:read")

      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"instances" => "write"}}
      })

      summary = render(element(view, "[data-testid='api-token-scope-summary']"))
      assert summary =~ "wallet:read"
      assert summary =~ "instances:write"

      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"wallet" => "none"}}
      })

      refute render(element(view, "[data-testid='api-token-scope-summary']")) =~ "wallet:read"
      assert render(element(view, "[data-testid='api-token-scope-summary']")) =~ "instances:write"

      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"instances" => "none"}}
      })

      assert has_element?(
               view,
               "[data-testid='api-token-scope-group-instances'][data-level='none']"
             )

      # The inclusion cue cleared with the level.
      read_option = render(element(view, "[data-testid='api-token-scope-instances-read']"))
      assert read_option =~ ~s(data-included="false")
      refute read_option =~ "✓ Read"

      assert render(element(view, "[data-testid='api-token-scope-summary']")) =~
               "No scopes selected."
    end

    test "crafted scope-change payloads are ignored, never crash, and leave valid state", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      # A non-map token payload and a missing one land the no-op head.
      assert render_change(view, "scope-change", %{"token" => "junk"}) =~ "API tokens"
      assert render_change(view, "scope-change", %{}) =~ "API tokens"

      # A non-map domain_levels leaves the current levels standing.
      assert render_change(view, "scope-change", %{
               "token" => %{"name" => "", "domain_levels" => "junk"}
             }) =~ "API tokens"

      # A non-binary name falls back to "" (the form source resets).
      render_change(view, "scope-change", %{
        "token" => %{"name" => ["a"], "domain_levels" => %{"instances" => "read"}}
      })

      assert has_element?(
               view,
               "[data-testid='api-token-scope-group-instances'][data-level='read']"
             )

      assert render(element(view, "[data-testid='api-token-name-input']")) =~ ~s(value="")

      # Write on a read-only domain and an unknown domain are both
      # ignored: @scope_levels only ever holds expandable entries.
      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"wallet" => "write"}}
      })

      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"admin" => "read"}}
      })

      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"instances" => "admin"}}
      })

      assert has_element?(view, "[data-testid='api-token-scope-group-wallet'][data-level='none']")

      assert has_element?(
               view,
               "[data-testid='api-token-scope-group-instances'][data-level='read']"
             )

      summary = render(element(view, "[data-testid='api-token-scope-summary']"))
      assert summary =~ "Minted scopes (1):"
      assert summary =~ "instances:read"
      refute summary =~ "wallet:read"
    end

    test "a struct domain_levels payload is ignored like any non-map", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      assert render_change(
               view,
               "scope-change",
               %{"token" => %{"name" => "", "domain_levels" => %URI{path: "x"}}}
             ) =~ "API tokens"

      assert has_element?(
               view,
               "[data-testid='api-token-scope-group-instances'][data-level='none']"
             )
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
            token: %{name: "ci deploys", domain_levels: %{instances: "write", wallet: "read"}}
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
      # Write expands to both scopes, in catalog order; the read-only
      # wallet contributes its read only.
      assert row.scopes == ["instances:read", "instances:write", "wallet:read"]

      # The list refreshed with the new row.
      row_html = render(element(view, "[data-testid='api-token-row']"))
      assert row_html =~ "ci deploys"
      assert row_html =~ "instances:read, instances:write, wallet:read"
      refute row_html =~ raw

      # The submission is disarmed: the form re-keyed (a changed id
      # replaces the subtree, clearing the dirty input a value patch
      # cannot reach), so a second click cannot mint a duplicate.
      refute has_element?(view, "#api-token-form-0")
      assert has_element?(view, "#api-token-form-1")

      # The levels reset with the form: every group back at none and
      # the summary back to the identity-only line.
      for key <- ["instances", "backups", "gateways", "wallet", "catalog", "organizations"] do
        assert has_element?(
                 view,
                 "[data-testid='api-token-scope-group-#{key}'][data-level='none']"
               )
      end

      assert render(element(view, "[data-testid='api-token-scope-summary']")) =~
               "No scopes selected."

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

    test "a failed submit keeps the picked levels too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_change(view, "scope-change", %{
        "token" => %{"name" => "", "domain_levels" => %{"gateways" => "write"}}
      })

      view
      |> form("#api-token-form-0", %{token: %{name: "   "}})
      |> render_submit()

      assert has_element?(view, "#flash-error", "Give the token a name first.")

      # Same disarm posture as the plain failure, plus the levels: the
      # user fixes the name without picking everything again.
      assert has_element?(view, "#api-token-form-0")
      refute has_element?(view, "#api-token-form-1")

      assert has_element?(
               view,
               "[data-testid='api-token-scope-group-gateways'][data-level='write']"
             )

      summary = render(element(view, "[data-testid='api-token-scope-summary']"))
      assert summary =~ "gateways:read"
      assert summary =~ "gateways:write"
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

    test "a crafted write level on a read-only domain is refused by the expansion", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "domain_levels" => %{"wallet" => "write"}}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "the catalog's crafted write level is refused too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "domain_levels" => %{"catalog" => "write"}}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "a crafted unknown domain is refused by the expansion", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "domain_levels" => %{"admin" => "read"}}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "a crafted unknown level is refused by the expansion", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "domain_levels" => %{"instances" => "admin"}}
      })

      assert has_element?(view, "#flash-error", "The scope selection wasn't valid.")
      assert has_element?(view, "[data-testid='api-tokens-empty']")
    end

    test "a crafted non-map domain_levels is refused without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/developer")

      render_click(view, "create-token", %{
        "token" => %{"name" => "forged", "domain_levels" => "junk"}
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
