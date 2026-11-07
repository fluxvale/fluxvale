defmodule FluxValeWeb.AdminWalletDetailLiveTest do
  @moduledoc false

  # The wallet detail surface (#501): the facts, the ledger with its
  # keyset pagination, and the two writes. The route gates are the
  # shared live_session's arms; the write paths are additionally
  # pinned at the domain seam with a non-admin actor (Forbidden),
  # because the route gate is the only thing standing between a
  # non-admin and these views. The reversal seam is system-level by
  # design (no actor-facing reversal action exists — the flagged gap),
  # so its gate is pinned as the surface enforces it: the
  # actor-authorized read plus the platform-admin predicate.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.SessionHelpers

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-wallet-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    {org, wallet} = funded_wallet!()

    %{
      admin: admin,
      org: org,
      wallet: wallet,
      conn: SessionHelpers.sign_in(conn, admin),
      bare_conn: conn
    }
  end

  # `{org, wallet}` through the same seams the fixtures always ride;
  # `balance_cents: 0` mints an untouched ledger.
  defp funded_wallet!(opts \\ []) do
    {org, _owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)
    cents = Keyword.get(opts, :balance_cents, 10_000)

    if cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, cents, reason: :adjustment)
    end

    {org, wallet}
  end

  defp ledger_entries!(wallet, admin) do
    LedgerEntry
    |> Ash.Query.for_read(:list_for_wallet, %{wallet_id: wallet.id}, actor: admin)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.read!(page: [limit: 100])
    |> Map.get(:results)
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid^='admin-wallet-entry-']")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.attribute("data-testid")
      |> Enum.join("")
      |> String.replace_prefix("admin-wallet-entry-", "")
    end)
  end

  describe "the facts" do
    test "mounts the org's wallet with its balance, runway, and back-link", %{
      conn: conn,
      org: org,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert has_element?(view, "[data-testid='admin-wallet-detail']")
      assert has_element?(view, "h1", org.name)
      assert text_of(view, "[data-testid='wallet-balance']") =~ "$100.00"

      # No instances exist, so nothing burns.
      assert text_of(view, "[data-testid='wallet-runway']") =~ "No active burn"

      assert has_element?(
               view,
               "[data-testid='admin-wallet-back-link'][href='/admin/billing']"
             )
    end

    test "the destroy clock reads with honest gravity when the balance is below zero", %{
      conn: conn
    } do
      {org, wallet} = funded_wallet!(balance_cents: 500)
      {:ok, _debit} = Billing.debit_wallet(wallet, 1_000 * 10_000)

      anchored_at = DateTime.add(DateTime.utc_now(), -2, :day)

      wallet
      |> Ash.Changeset.for_update(:set_ladder_state, %{negative_since: anchored_at},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert has_element?(view, "[data-testid='admin-wallet-destroy-clock']")
      assert has_element?(view, "[data-testid='admin-wallet-destroy-clock']", "below zero")
      assert has_element?(view, "[data-testid='admin-wallet-destroy-clock']", "30 days after")

      # The runway names the depletion the member surface sees too.
      assert text_of(view, "[data-testid='wallet-runway']") =~ "Depleted"

      # The anchored date renders: the countdown's anchor, not a mystery.
      assert text_of(view, "[data-testid='admin-wallet-destroy-clock']") =~
               Calendar.strftime(anchored_at, "%b %d, %Y")

      assert org
    end

    test "a negative balance with no anchor yet names the pending clock", %{conn: conn} do
      {_org, wallet} = funded_wallet!(balance_cents: 500)
      {:ok, _debit} = Billing.debit_wallet(wallet, 1_000 * 10_000)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert has_element?(view, "[data-testid='admin-wallet-destroy-clock']", "below zero")

      assert has_element?(
               view,
               "[data-testid='admin-wallet-destroy-clock']",
               "next automatic check"
             )
    end

    test "an unknown wallet redirects back to the table", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/billing"}}} =
               live(conn, "/admin/billing/wallets/#{Ecto.UUID.generate()}")
    end
  end

  describe "the waiver flip" do
    test "confirms with the contract in the copy, then flips", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert text_of(view, "[data-testid='admin-wallet-waiver-state']") == "Not waived"

      view
      |> element("[data-testid='admin-wallet-waiver-flip']")
      |> render_click()

      # The consequence panel states exactly what the waiver does and
      # what it never does.
      assert has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='destructive-confirm']", "has-paid gate")
      assert has_element?(view, "[data-testid='destructive-confirm']", "private access")
      assert has_element?(view, "[data-testid='destructive-confirm']", "moves no money")
      assert has_element?(view, "[data-testid='destructive-confirm']", "posts no ledger row")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "waives nothing spendable"
             )

      assert has_element?(view, "[data-testid='admin-wallet-waiver-confirm']")
      assert has_element?(view, "[data-testid='admin-wallet-waiver-cancel']")

      # Cancel is a way out: nothing flipped.
      view
      |> element("[data-testid='admin-wallet-waiver-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='destructive-confirm']")

      {:ok, fresh} = Wallet.get_by_organization(wallet.organization_id, actor: admin)
      assert fresh.paywall_waived == false

      # This time the decisive button.
      view
      |> element("[data-testid='admin-wallet-waiver-flip']")
      |> render_click()

      view
      |> element("[data-testid='admin-wallet-waiver-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "No money moved")
      assert text_of(view, "[data-testid='admin-wallet-waiver-state']") == "Waived"

      {:ok, flipped} = Wallet.get_by_organization(wallet.organization_id, actor: admin)
      assert flipped.paywall_waived == true
    end

    test "removing the waiver names what closes", %{conn: conn, admin: admin, wallet: wallet} do
      {:ok, _waived} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert text_of(view, "[data-testid='admin-wallet-waiver-state']") == "Waived"

      view
      |> element("[data-testid='admin-wallet-waiver-flip']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']", "closes again")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "lock until the org tops up"
             )

      view
      |> element("[data-testid='admin-wallet-waiver-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "The has-paid gate is closed again")
      assert text_of(view, "[data-testid='admin-wallet-waiver-state']") == "Not waived"
    end
  end

  describe "the goodwill credit" do
    test "the submit fences the wire (the keyless post's double-click guard)", %{
      conn: conn,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      html =
        view
        |> element("#admin-wallet-goodwill-form")
        |> render()

      button =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-testid='admin-wallet-goodwill-submit']")
        |> Enum.at(0)

      assert LazyHTML.attribute(button, "phx-disable-with") == ["Posting..."]
    end

    test "posts immediately as an adjustment and renders the row at the top", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "500"}})

      # The consequence copy states the keyless contract.
      assert has_element?(view, "#flash-info", "Posted $5.00 as an adjustment credit")
      assert has_element?(view, "#flash-info", "cannot be un-posted, only reversed")

      # The posted row sits at the top of the ledger (the operator
      # review the domain names as the guard). The setup wallet's
      # funding grant sits below it.
      [posted | _rest] = ledger_entries!(wallet, admin)
      rows = row_ids(view)
      assert List.first(rows) == posted.id

      assert text_of(view, "[data-testid='admin-wallet-amount-#{posted.id}']") ==
               "+$5.00"

      assert has_element?(view, "[data-testid='admin-wallet-entry-#{posted.id}']", "Adjustment")

      # The facts moved with the post.
      assert text_of(view, "[data-testid='wallet-balance']") =~ "$105.00"

      # The ledger truth behind the row.
      assert posted.type == :credit
      assert posted.reason == :adjustment
      assert posted.amount == 500
    end

    test "an amount that is not a whole positive number of cents is refused", %{
      conn: conn,
      admin: admin
    } do
      {org, wallet} = funded_wallet!(balance_cents: 0)
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      for bad <- ["0", "-3", "abc", "", "5.50"] do
        view
        |> element("#admin-wallet-goodwill-form")
        |> render_submit(%{"goodwill" => %{"amount_cents" => bad}})

        assert has_element?(view, "#flash-error", "whole number of US cents")
        assert has_element?(view, "#flash-error", "Nothing was posted")
      end

      assert ledger_entries!(wallet, admin) == []
      assert org
    end
  end

  describe "the reversal" do
    test "posts the compensating row and the original stays", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, original} = LedgerEntry.grant_goodwill(wallet.id, 250, actor: admin)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      view
      |> element("[data-testid='admin-wallet-reverse-#{original.id}']")
      |> render_click()

      # The consequence panel: a compensating entry, the original stays.
      assert has_element?(view, "[data-testid='destructive-confirm']", "compensating debit")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "original entry stays in the ledger"
             )

      assert has_element?(view, "[data-testid='admin-wallet-reverse-confirm']")

      # Cancel is a way out.
      view
      |> element("[data-testid='admin-wallet-reverse-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='destructive-confirm']")

      entries = ledger_entries!(wallet, admin)
      assert [] = Enum.filter(entries, &(&1.reverses_id == original.id))

      # This time the decisive button.
      view
      |> element("[data-testid='admin-wallet-reverse-#{original.id}']")
      |> render_click()

      view
      |> element("[data-testid='admin-wallet-reverse-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "compensating reversal")
      assert has_element?(view, "#flash-info", "original entry stays")

      # The reversal renders at the top with its own badge; the
      # original stays in the ledger, marked reversed, lever gone.
      rows = row_ids(view)
      assert [reversal_id, original_id] = Enum.take(rows, 2)
      assert reversal_id != original.id
      assert original_id == original.id

      assert text_of(view, "[data-testid='admin-wallet-amount-#{reversal_id}']") ==
               "-$2.50"

      assert has_element?(view, "[data-testid='admin-wallet-entry-#{reversal_id}']", "Reversal")
      assert has_element?(view, "[data-testid='admin-wallet-entry-#{original.id}']", "Reversed")

      refute has_element?(view, "[data-testid='admin-wallet-reverse-#{original.id}']")

      # The balance is back where the credit found it.
      assert text_of(view, "[data-testid='wallet-balance']") =~ "$100.00"

      # The ledger truth: one compensating debit pointing at the
      # original, which is still there.
      final_entries = ledger_entries!(wallet, admin)

      assert [reversal] = Enum.filter(final_entries, &(&1.reverses_id == original.id))
      assert reversal.type == :debit
      assert reversal.reason == :refund
      assert reversal.amount == -250
      assert Enum.any?(final_entries, &(&1.id == original.id))
    end

    test "a second reversal is refused and the ledger refreshes honestly", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, original} = LedgerEntry.grant_goodwill(wallet.id, 250, actor: admin)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      # A racing tab (or the stale frame) opens the confirm before the
      # reversal lands; the domain's guard answers the click. The
      # event is driven directly — the same crafted-frame shape the
      # people surface pins.
      {:ok, _reversal} = Billing.reverse_entry(original)

      render_click(view, "open-reverse", %{"id" => original.id})

      view
      |> element("[data-testid='admin-wallet-reverse-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "already reversed")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a reveal naming a debit row or an unknown entry refuses and refreshes", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, original} = LedgerEntry.grant_goodwill(wallet.id, 250, actor: admin)
      {:ok, _reversal} = Billing.reverse_entry(original)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      # The reversal row is a debit (its lever never rendered); a
      # crafted frame driving it lands in the refused arm.
      [reversal | _rest] = ledger_entries!(wallet, admin)

      render_click(view, "open-reverse", %{"id" => reversal.id})

      assert has_element?(view, "#flash-error", "That entry changed")
      refute has_element?(view, "[data-testid='destructive-confirm']")

      # An unknown id: the same honest arm.
      render_click(view, "open-reverse", %{"id" => Ecto.UUID.generate()})
      assert has_element?(view, "#flash-error", "That entry changed")

      # The ledger is unmoved.
      entries = ledger_entries!(wallet, admin)
      assert [_reversal_again] = Enum.filter(entries, &(&1.reverses_id == original.id))
    end
  end

  describe "the ledger pagination" do
    test "keys keyset pages, newest first, and retires the button at exhaustion", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      # The setup wallet's funding grant is the ledger's oldest row.
      [funding | _rest] = ledger_entries!(wallet, admin)

      grants =
        for _n <- 1..26 do
          {:ok, entry} = Billing.grant_credits(wallet, 1, reason: :adjustment)
          entry
        end

      newest = List.last(grants)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      # First page: the 25 newest, the last grant at the top.
      rows = row_ids(view)
      assert length(rows) == 25
      assert List.first(rows) == newest.id
      refute Enum.member?(rows, funding.id)

      view
      |> element("[data-testid='admin-wallet-load-more']")
      |> render_click()

      # The last page appended the final two rows (the oldest grant
      # and the funding grant) and retired the button.
      rows_after = row_ids(view)
      assert length(rows_after) == 27
      assert List.last(rows_after) == funding.id
      refute has_element?(view, "[data-testid='admin-wallet-load-more']")

      assert admin
    end

    test "an empty ledger reads honestly", %{conn: conn} do
      {_org, wallet} = funded_wallet!(balance_cents: 0)
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert has_element?(view, "[data-testid='admin-wallet-ledger-empty']", "No activity yet.")
    end

    test "a posting's provider reference renders read-only", %{conn: conn, wallet: wallet} do
      {:ok, entry} =
        Billing.grant_credits(wallet, 100,
          reason: :purchase,
          idempotency_key: "polar:capture-123"
        )

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert text_of(view, "[data-testid='admin-wallet-reference-#{entry.id}']") ==
               "polar:capture-123"
    end

    test "the welcome grant's badge renders in the ledger grammar", %{conn: conn, admin: admin} do
      # The welcome grant rides JIT provisioning (#122): the setup
      # admin's own personal-org wallet carries exactly one.
      {:ok, org} = Accounts.personal_org_for_user(admin.id, authorize?: false)
      {:ok, wallet} = Billing.ensure_wallet(org)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      [welcome | _rest] = ledger_entries!(wallet, admin)
      assert welcome.reason == :welcome

      assert has_element?(
               view,
               "[data-testid='admin-wallet-entry-#{welcome.id}']",
               "Welcome credit"
             )

      assert has_element?(view, "[data-testid='admin-wallet-entry-#{welcome.id}'] .hero-sparkles")
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn, wallet: wallet} do
      conn = get(conn, "/admin/billing/wallets/#{wallet.id}")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn, wallet: wallet} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/billing/wallets/#{wallet.id}")

      assert conn.status == 403
    end

    test "non-admin actors are Forbidden on every write path", %{admin: admin, wallet: wallet} do
      non_admin = SessionHelpers.user!()

      # The waiver flip: the one actor-facing wallet update.
      assert {:error, %Ash.Error.Forbidden{}} =
               Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: non_admin)

      # The goodwill credit: the admin-only posting exception.
      assert {:error, %Ash.Error.Forbidden{}} =
               LedgerEntry.grant_goodwill(wallet.id, 500, actor: non_admin)

      # The reversal: the seam is system-level (no actor-facing
      # reversal action exists — the flagged gap), so the surface's
      # handler gates it on the actor-authorized read plus the
      # platform-admin predicate. The read arm renders the denial as
      # NotFound (the not-here answer) for a non-member.
      {:ok, original} = LedgerEntry.grant_goodwill(wallet.id, 250, actor: admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(LedgerEntry, original.id, actor: non_admin)

      refute ActorIsPlatformAdmin.platform_admin?(non_admin)
    end
  end
end
