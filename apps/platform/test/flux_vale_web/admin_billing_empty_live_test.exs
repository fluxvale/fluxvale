defmodule FluxValeWeb.AdminBillingEmptyLiveTest do
  @moduledoc false

  # The wallets table's honest empty state (#501), in its own module:
  # through actions the state is unreachable (every created account
  # provisions its personal-org wallet at signup), so the suite's
  # setup cannot create any wallet — the admin here is seeded, the
  # sanctioned escape for states actions cannot produce
  # (BillingFixtures' own posture). The session resolves through the
  # email mirror, so the seed backfills it.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      Ash.Seed.seed!(User, %{
        username: "admin-billing-empty-#{@n}",
        platform_role: :admin
      })

    AccountsFixtures.attach_primary_email!(admin, "admin-billing-empty-#{@n}@fluxvale.com")

    %{conn: SessionHelpers.sign_in(conn, admin)}
  end

  test "a zero-wallet day reads honestly", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/billing")

    assert has_element?(view, "[data-testid='admin-billing-list'] p", "No wallets yet.")

    assert has_element?(
             view,
             "[data-testid='admin-billing-list']",
             "Every org carries exactly one wallet"
           )

    refute has_element?(view, "[data-testid^='admin-billing-org-']")
  end
end
