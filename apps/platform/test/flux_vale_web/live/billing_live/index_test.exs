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
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers

  # Micro-cents per cent — Billing's debit/credit unit (the wallet
  # shape test below trades in it).
  @micro_per_cent 10_000

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

  # The band's runway formatter arms, one wallet shape each — the S4
  # sweep, against the billing band's copy (BillingComponents'). Each
  # shape owns its user so the burn arithmetic stays flat.
  test "runway copy tracks the balance-to-burn shape" do
    InstanceFixtures.local_cluster!()

    check = fn monthly_cents, cents_left, expected_runway ->
      {user, conn} = SessionHelpers.user_with_session(Phoenix.ConnTest.build_conn())

      org = AccountsFixtures.personal_org!(user)
      {:ok, wallet} = Billing.ensure_wallet(org)

      # Deploy first (creates are balance-gated), then shape the wallet.
      version = InstanceFixtures.app_version!(monthly_cents: monthly_cents)
      instance = InstanceFixtures.instance!(version, user)
      InstanceFixtures.walk_to!(instance, :running)

      {:ok, balance} = Billing.balance(wallet, authorize?: false)

      if balance != cents_left do
        Billing.debit_wallet(wallet, (balance - cents_left) * @micro_per_cent)
      end

      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "[data-testid='wallet-runway']", expected_runway)
    end

    check.(1000, 2, "≈ 1 hour")
    check.(1000, 1, "under an hour")
    check.(100, 100, "≈ 30 days")
    check.(100, 300, "≈ 3 months")

    # The burn hint arm: a live burn names its monthly rate.
    {user, conn} = SessionHelpers.user_with_session(Phoenix.ConnTest.build_conn())
    version = InstanceFixtures.app_version!(monthly_cents: 100)
    instance = InstanceFixtures.instance!(version, user)
    InstanceFixtures.walk_to!(instance, :running)

    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(
             view,
             "[data-testid='wallet-runway']",
             ~r/at \$[\d.]+\/mo current burn/
           )

    # Exact cents: the hint must ROUND the reconstructed rate, not
    # truncate it again — ComputeRunway's µ¢/h conversion already
    # floors, and a second floor displayed $1.00/mo as "$0.99/mo"
    # (CodeRabbit #351).
    assert has_element?(view, "[data-testid='wallet-runway']", "at $1.00/mo current burn")
  end

  # The wallet crossed zero: no "under an hour" sugar on a spent
  # balance — the band reads Depleted over the minus-signed value.
  test "a spent wallet's runway reads Depleted", %{conn: conn, wallet: wallet} do
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    {:ok, _debit} = Billing.debit_wallet(wallet, 200_000_000)

    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(view, "[data-testid='wallet-runway']", "Depleted")
  end

  # The fresh-account shape: nothing deployed → no burn → the
  # infinite-runway arm with the neutral hint.
  test "a wallet with no burn reads No active burn", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(view, "[data-testid='wallet-runway']", "No active burn")
    assert has_element?(view, "[data-testid='wallet-runway']", "Nothing burning right now.")
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

  test "the balance card's notice links the refund policy (#140)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/billing")

    assert has_element?(
             view,
             "a[data-testid='topup-refund-policy'][href='/policies/refund']",
             "refund policy"
           )
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

    # Append, not prepend: the older page lands AFTER the first page's
    # rows in the rendered DOM (the stream insert rides at: -1).
    html = render(view)
    assert {first_page_last, 6} = :binary.match(html, "+$0.06")
    assert {appended_first, 6} = :binary.match(html, "+$0.05")
    assert first_page_last < appended_first

    # exhausted-page click (double-click race) is a no-op, not a crash
    render_click(view, "load-more", %{})
    assert has_element?(view, "[data-testid='ledger-row']", "+$0.01")
  end

  test "a user without an org is turned away", %{conn: conn} do
    # Ash.seed! — the only way to produce an org-less user: the create
    # action's JIT change always provisions one (state actions can't
    # produce, the documented seed! exception). backfill_email! adds the
    # row the T1 backfill gave every pre-existing user (#285 T3 resolves
    # identity through the table).
    orgless = Ash.Seed.seed!(User, %{email: "orgless-#{System.unique_integer()}@fluxvale.test"})

    AccountsFixtures.backfill_email!(orgless)

    conn = SessionHelpers.sign_in(conn, orgless)

    case live(conn, ~p"/billing") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end
end
