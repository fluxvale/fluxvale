defmodule FluxValeWeb.OrganizationLive.SettingsTest do
  @moduledoc false

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    owner = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(owner)

    {:ok, conn: SessionHelpers.sign_in(conn, owner), owner: owner, org: org}
  end

  test "the owner sees the settings shell — org header, General tab, the form", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    assert has_element?(view, "[data-testid='org-name']", org.name)
    assert has_element?(view, "[data-testid='org-slug']", org.slug)
    assert has_element?(view, "#org-general-form")
    assert has_element?(view, "[data-testid='slug-preview']", "/organizations/#{org.slug}")
  end

  test "the tab nav renders exactly one tab — General (no dead tabs ship)", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    assert has_element?(view, "[data-testid='org-settings-tab-general']", "General")

    # Count the tab keys, not just the container: a dead tab injected by a
    # mutation must fail this. (LiveViewTest has no count API, and
    # LazyHTML's parser chokes on the page's script tags — hence the
    # rendered-HTML count of the testid each tab renders exactly once.)
    tab_count =
      view
      |> render()
      |> then(&Regex.scan(~r/data-testid="org-settings-tab-[a-z-]+"/, &1))
      |> length()

    assert tab_count == 1
  end

  test "the slug preview follows the input live", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "brand-new-address"})
    |> render_change()

    assert has_element?(view, "[data-testid='slug-preview']", "/organizations/brand-new-address")
  end

  test "the owner renames the display name (slug unchanged)", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{name: "Renamed Co", slug: org.slug})
    |> render_submit()

    assert has_element?(view, "[data-testid='org-name']", "Renamed Co")
    assert has_element?(view, "[data-testid='org-slug']", org.slug)

    assert {:ok, renamed} = Organization.get_by_slug(org.slug, actor: owner)
    assert renamed.name == "Renamed Co"
  end

  test "the owner renames the slug — confirm names the target, then the page lives there", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    # First submit arms the confirm step — the copy names the destination.
    view
    |> form("#org-general-form", organization: %{name: org.name, slug: "moved-slug"})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")
    assert has_element?(view, "#slug-confirm", "/organizations/moved-slug")

    assert {:ok, unchanged} = Organization.get_by_slug(org.slug, actor: owner)
    assert unchanged.slug == org.slug

    # The explicit confirm applies the rename.
    view
    |> element("[data-testid='confirm-rename']")
    |> render_click()

    assert_redirect(view, ~p"/organizations/moved-slug/settings")

    assert {:ok, moved} = Organization.get_by_slug("moved-slug", actor: owner)
    assert moved.id == org.id
  end

  test "editing the field after arming disarms: a confirm click applies nothing", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "armed-alpha"})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")

    view
    |> form("#org-general-form", organization: %{slug: "edited-beta"})
    |> render_change()

    # The arm died with the edit — the panel hides and the queued confirm
    # (real or crafted) is a no-op.
    refute has_element?(view, "[data-testid='slug-confirm']")

    render_click(view, "confirm-rename", %{})

    assert {:ok, unchanged} = Organization.get_by_slug(org.slug, authorize?: false)
    assert unchanged.slug == org.slug
  end

  test "an invalid edit while armed disarms too", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "armed-alpha"})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")

    view
    |> form("#org-general-form", organization: %{slug: "Not Valid!"})
    |> render_change()

    refute has_element?(view, "[data-testid='slug-confirm']")
  end

  test "a validate that still holds the armed value keeps the panel armed", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "steady-slug"})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")

    # A keystroke round trip that re-validates to the same value — the arm
    # survives, and the confirm still applies exactly what was named.
    view
    |> form("#org-general-form", organization: %{slug: "steady-slug"})
    |> render_change()

    assert has_element?(view, "[data-testid='slug-confirm']")

    view
    |> element("[data-testid='confirm-rename']")
    |> render_click()

    assert {:ok, moved} = Organization.get_by_slug("steady-slug", actor: owner)
    assert moved.id == org.id
  end

  test "a confirm click with no armed panel is a no-op", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    # A phx-change alone never arms — a crafted confirm-rename must not rename.
    view
    |> form("#org-general-form", organization: %{slug: "never-confirmed"})
    |> render_change()

    render_click(view, "confirm-rename", %{})

    assert {:ok, unchanged} = Organization.get_by_slug(org.slug, authorize?: false)
    assert unchanged.slug == org.slug
  end

  test "cancel disarms, so a queued confirm click applies nothing", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "cancelled-slug"})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")

    render_click(view, "cancel-rename", %{})
    render_click(view, "confirm-rename", %{})

    refute has_element?(view, "[data-testid='slug-confirm']")
    assert {:ok, unchanged} = Organization.get_by_slug(org.slug, authorize?: false)
    assert unchanged.slug == org.slug
  end

  test "saving a new slug while armed re-arms for the new value; confirm applies it", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "armed-alpha"})
    |> render_submit()

    view
    |> form("#org-general-form", organization: %{slug: "edited-beta"})
    |> render_submit()

    # Re-armed for the submitted slug — the copy names it now.
    assert has_element?(view, "[data-testid='slug-confirm']")
    assert has_element?(view, "#slug-confirm", "/organizations/edited-beta")

    view
    |> element("[data-testid='confirm-rename']")
    |> render_click()

    assert {:ok, moved} = Organization.get_by_slug("edited-beta", actor: owner)
    assert moved.id == org.id
  end

  test "the old slug reads as not-here after a rename — flash + redirect home", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "gone-slug"})
    |> render_submit()

    view
    |> element("[data-testid='confirm-rename']")
    |> render_click()

    assert_redirect(view, ~p"/organizations/gone-slug/settings")

    assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
             live(conn, ~p"/organizations/#{org.slug}/settings")

    assert flash["error"] == "Organization not found."
    assert {:ok, _moved} = Organization.get_by_slug("gone-slug", actor: owner)
  end

  test "a slug collision shows the field error and changes nothing", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    other = AccountsFixtures.personal_org!(AccountsFixtures.user!())

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: other.slug})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")

    view
    |> element("[data-testid='confirm-rename']")
    |> render_click()

    # The identity conflict maps to a friendly field-level message; the
    # row is untouched.
    assert has_element?(view, "#org-general-form", "has already been taken")

    assert {:ok, unchanged} = Organization.get_by_slug(org.slug, actor: owner)
    assert unchanged.slug == org.slug
    assert unchanged.id == org.id
  end

  test "an invalid slug format is rejected without arming the confirm step", %{
    conn: conn,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "Not Valid!"})
    |> render_submit()

    refute has_element?(view, "[data-testid='slug-confirm']")

    assert has_element?(
             view,
             "#org-general-form",
             "must contain only lowercase alphanumeric characters and hyphens"
           )

    assert {:ok, unchanged} = Organization.get_by_slug(org.slug, authorize?: false)
    assert unchanged.slug == org.slug
  end

  test "a form mounted before a rename cannot write the stale slug back", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, tab1, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")
    {:ok, tab2, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    tab1
    |> form("#org-general-form", organization: %{name: "Tab One Name", slug: "tab1-target"})
    |> render_submit()

    tab1
    |> element("[data-testid='confirm-rename']")
    |> render_click()

    # tab2's form predates the rename: its "name-only" save looks
    # unchanged to itself, skips the confirm step — and must fail stale
    # instead of silently moving the address back or clobbering tab1's
    # newer name.
    tab2
    |> form("#org-general-form", organization: %{name: "Tab Two Name", slug: org.slug})
    |> render_submit()

    assert has_element?(tab2, "#flash-error", "This organization changed underneath you")

    assert {:ok, current} = Organization.get_by_slug("tab1-target", actor: owner)
    assert current.name == "Tab One Name"

    assert {:error, _gone} = Organization.get_by_slug(org.slug, actor: owner)
  end

  test "a non-owner member is gated away from settings", %{conn: conn, org: org} do
    member = AccountsFixtures.user!()

    # Sanctioned precondition: nothing in the system creates :member rows
    # yet, so the row rides the action with authorize?: false.
    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    member_conn = SessionHelpers.sign_in(conn, member)

    assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
             live(member_conn, ~p"/organizations/#{org.slug}/settings")

    assert flash["error"] == "Only organization owners can access settings."
  end
end
