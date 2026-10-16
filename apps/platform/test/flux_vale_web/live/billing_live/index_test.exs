defmodule FluxValeWeb.BillingLive.IndexTest do
  @moduledoc false

  # The billing surface (#123): balance as USD from integer cents, the
  # signed ledger rows, the add-credits placeholder, and the "Load more"
  # keyset walk. No K8s, no mail — pure reads over the wallet policies.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Billing
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    org = AccountsFixtures.personal_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)

    # Pin the start at exactly zero: the fixture's welcome grant and
    # #131's signup $3 vary — the tests below own their arithmetic
    # (debit the whole balance; posting never checks it).
    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    {:ok, _drain} = Billing.debit_wallet(wallet, balance * 10_000)

    %{user: user, conn: conn, wallet: wallet}
  end

  test "renders the balance as USD from integer cents", %{conn: conn, wallet: wallet} do
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    {:ok, _debit} = Billing.debit_wallet(wallet, 250_000)

    {:ok, view, _html} = live(conn, ~p"/billing")

    # 10_000¢ − 25¢ = 9_975¢
    assert has_element?(view, "[data-testid='wallet-balance']", "$99.75")
  end

  test "renders signed ledger rows — credits and debits", %{conn: conn, wallet: wallet} do
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    {:ok, _debit} = Billing.debit_wallet(wallet, 250_000)

    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(view, "[data-testid='ledger-row']", "+$100.00")
    assert has_element?(view, "[data-testid='ledger-row']", "-$0.25")
  end

  test "a negative balance renders with a minus sign", %{conn: conn, wallet: wallet} do
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    # 200_000_000 µ¢ = 20_000¢ against a 10_000¢ grant — posting never
    # checks the balance, so the ledger lands at −10_000¢.
    {:ok, _debit} = Billing.debit_wallet(wallet, 200_000_000)

    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(view, "[data-testid='wallet-balance']", "-$100.00")
  end

  test "a zero balance renders $0.00", %{conn: conn} do
    # The setup drain leaves the wallet at exactly 0 — its rows show in
    # history (nothing posts an empty ledger anymore: signup grants $3,
    # #131), so the zero-balance render is the assertion here.
    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(view, "[data-testid='wallet-balance']", "$0.00")
  end

  test "add credits opens the top-up wizard (#137)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/billing")

    assert render(element(view, "#add-credits")) =~ "/billing/topup"
  end

  test "load more appends the older page and retires at the end", %{conn: conn, wallet: wallet} do
    # 30 rows; the i-th grant posts i cents — amounts double as order
    # markers. Page 1 carries the newest 25 (amounts 30..6).
    for i <- 1..30 do
      {:ok, _entry} = Billing.grant_credits(wallet, i)
    end

    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(view, "[data-testid='ledger-row']", "+$0.30")
    refute has_element?(view, "[data-testid='ledger-row']", "+$0.05")

    assert has_element?(view, "#load-more")

    view
    |> element("#load-more")
    |> render_click()

    assert has_element?(view, "[data-testid='ledger-row']", "+$0.05")
    assert has_element?(view, "[data-testid='ledger-row']", "+$0.01")
    refute has_element?(view, "#load-more")

    # exhausted-page click (double-click race) is a no-op, not a crash
    render_click(view, "load-more", %{})
    assert has_element?(view, "[data-testid='ledger-row']", "+$0.01")
  end

  test "a user without an org is turned away", %{conn: conn} do
    # Ash.seed! — the only way to produce an org-less user: the create
    # action's JIT change always provisions one (state actions can't
    # produce, the documented seed! exception).
    orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})
    conn = SessionHelpers.sign_in(conn, orgless)

    case live(conn, ~p"/billing") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end
end
