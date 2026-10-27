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
    assert has_element?(view, "[data-testid='org-settings-tab-general']", "General")
    assert has_element?(view, "#org-general-form")
    assert has_element?(view, "[data-testid='slug-preview']", "/organizations/#{org.slug}")

    # No dead tabs: General is the only tab until its content ships.
    assert has_element?(view, "[data-testid='org-settings-tabs']")
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

  test "the owner renames the slug — confirm step, then the page lives at the new address", %{
    conn: conn,
    owner: owner,
    org: org
  } do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    # First submit arms the confirm step — nothing has moved yet.
    view
    |> form("#org-general-form", organization: %{name: org.name, slug: "moved-slug"})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")

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

  test "cancel keeps the org where it is", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/settings")

    view
    |> form("#org-general-form", organization: %{slug: "cancelled-slug"})
    |> render_submit()

    assert has_element?(view, "[data-testid='slug-confirm']")

    view
    |> element("[data-testid='cancel-rename']")
    |> render_click()

    refute has_element?(view, "[data-testid='slug-confirm']")
    assert {:ok, ^org} = Organization.get_by_slug(org.slug, authorize?: false)
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

    case live(conn, ~p"/organizations/#{org.slug}/settings") do
      {:ok, old_view, _html} ->
        assert_redirect(old_view, ~p"/")

      # push_navigate in mount surfaces as live_redirect from live/2
      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/"
    end

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

  test "a non-owner member is gated away from settings", %{conn: conn, org: org} do
    member = AccountsFixtures.user!()

    # Sanctioned precondition: nothing in the system creates :member rows
    # yet, so the row rides the action with authorize?: false.
    Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
      authorize?: false
    )

    member_conn = SessionHelpers.sign_in(conn, member)

    case live(member_conn, ~p"/organizations/#{org.slug}/settings") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/"
    end
  end
end
