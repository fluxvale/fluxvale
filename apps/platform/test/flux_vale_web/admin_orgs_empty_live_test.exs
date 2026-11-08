defmodule FluxValeWeb.AdminOrgsEmptyLiveTest do
  @moduledoc false

  # The orgs table's honest empty state (#501), in its own module:
  # through actions the state is unreachable (every created account
  # provisions its personal org and wallet at signup), so the suite's
  # setup cannot empty the table — the admin here is seeded, the
  # sanctioned escape for states actions cannot produce. The session
  # resolves through the email mirror, so the seed backfills it.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      Ash.Seed.seed!(User, %{
        username: "admin-orgs-empty-#{@n}",
        platform_role: :admin
      })

    # #287's table-backed identity: seed! cannot write user_emails, so
    # the row the session resolution needs rides the fixture (the
    # #614 posture — the address is explicit now that users.email is
    # gone).
    AccountsFixtures.attach_primary_email!(admin, "admin-orgs-empty-#{@n}@fluxvale.com")

    %{conn: SessionHelpers.sign_in(conn, admin)}
  end

  test "a zero-org day reads honestly", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/orgs")

    assert has_element?(view, "[data-testid='admin-orgs-list'] p", "No orgs yet.")

    assert has_element?(
             view,
             "[data-testid='admin-orgs-list']",
             "An org appears here once its wallet exists"
           )

    refute has_element?(view, "[data-testid^='admin-orgs-org-']")

    # No dangling header over the empty state.
    refute has_element?(view, "[data-testid='admin-orgs-table-header']")
  end
end
