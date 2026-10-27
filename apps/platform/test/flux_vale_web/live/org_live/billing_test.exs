defmodule FluxValeWeb.OrganizationLive.BillingTest do
  @moduledoc false

  # The org billing view (#276): the /billing shape scoped to the URL's
  # org — balance and ledger for THAT org only, the not-found arm for
  # unknown slugs and non-members alike, and the "Load more" keyset
  # walk (mirrors BillingLive.IndexTest).

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  setup %{conn: conn} do
    user = AccountsFixtures.user!()
    org = AccountsFixtures.personal_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)

    # Pin the start at exactly zero: the fixture's welcome grant and
    # #131's signup $3 vary — the tests below own their arithmetic
    # (debit the whole balance; posting never checks it).
    {:ok, balance} = Billing.balance(wallet, authorize?: false)
    {:ok, _drain} = Billing.debit_wallet(wallet, balance * 10_000)

    %{user: user, org: org, wallet: wallet, conn: SessionHelpers.sign_in(conn, user)}
  end

  test "the member sees the org's balance and its ledger rows", %{
    conn: conn,
    org: org,
    wallet: wallet
  } do
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)
    {:ok, _debit} = Billing.debit_wallet(wallet, 250_000)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    # 10_000¢ − 25¢ = 9_975¢
    assert has_element?(view, "[data-testid='wallet-balance']", "$99.75")
    assert has_element?(view, "[data-testid='ledger-row']", "+$100.00")
    assert has_element?(view, "[data-testid='ledger-row']", "-$0.25")
  end

  test "the switcher names the viewed org as the active context", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    assert has_element?(view, "[data-testid='org-switcher-button']", org.name)
  end

  test "no top-up CTA — top-ups start from the personal billing page", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    refute has_element?(view, "#add-credits")
    assert has_element?(view, "a[data-testid='topup-link'][href='/billing']")
  end

  test "the ledger is scoped to the viewed org — another org's rows never appear", %{
    conn: conn,
    org: org,
    wallet: wallet
  } do
    # A second org with its own wallet and a distinctive row. System
    # seams only: ensure_wallet is the idempotent provisioning op and
    # grant_credits the posting op — no actor is involved (the same
    # posture the page's mount takes).
    other_org = AccountsFixtures.personal_org!(AccountsFixtures.user!())
    {:ok, other_wallet} = Billing.ensure_wallet(other_org)
    {:ok, _grant} = Billing.grant_credits(other_wallet, 123_456)

    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    assert has_element?(view, "[data-testid='ledger-row']", "+$100.00")
    refute has_element?(view, "[data-testid='ledger-row']", "+$1234.56")
  end

  test "load more appends the older page and retires at the end", %{
    conn: conn,
    org: org,
    wallet: wallet
  } do
    # 30 rows; the i-th grant posts i cents — amounts double as order
    # markers. Page 1 carries the newest 25 (amounts 30..6).
    for i <- 1..30 do
      {:ok, _entry} = Billing.grant_credits(wallet, i)
    end

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

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

  test "an org wallet with no ledger rows renders the empty state", %{conn: conn, user: user} do
    # A row-less wallet is a state actions can't produce: provisioning
    # always grants welcome credits in the same transaction, so the bare
    # shape (raw org + ensure_wallet, no grant) rides authorize?: false —
    # the sanctioned bootstrap posture (the #279 membership precondition).
    bare_org = Organization.create!(%{name: "Bare Org", slug: "bare-org"}, authorize?: false)
    {:ok, _wallet} = Billing.ensure_wallet(bare_org)

    Membership.create!(%{organization_id: bare_org.id, user_id: user.id, role: :owner},
      authorize?: false
    )

    {:ok, view, _html} = live(conn, ~p"/organizations/#{bare_org.slug}/billing")

    assert has_element?(view, "[data-testid='wallet-balance']", "$0.00")
    assert has_element?(view, "[data-testid='ledger-empty']", "No activity yet.")
    refute has_element?(view, "[data-testid='ledger-row']")
    refute has_element?(view, "#load-more")
  end

  test "an unknown slug is flash + redirect home — never a bare 404", %{conn: conn} do
    assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
             live(conn, ~p"/organizations/does-not-exist/billing")

    assert flash["error"] == "Organization not found."
  end

  test "a non-member's read is the same not-found arm (no enumeration)", %{conn: conn} do
    other_org = AccountsFixtures.personal_org!(AccountsFixtures.user!())

    assert {:error, {:live_redirect, %{flash: flash, to: "/"}}} =
             live(conn, ~p"/organizations/#{other_org.slug}/billing")

    assert flash["error"] == "Organization not found."
  end
end
