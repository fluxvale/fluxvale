defmodule FluxValeWeb.AdminWalletDetailLiveTest do
  @moduledoc false

  # The wallet detail surface (#501): the facts, the ledger with its
  # keyset pagination, and the three writes. The route gates are the
  # shared live_session's arms; the write paths are additionally pinned
  # at the domain seam with a non-admin actor (Forbidden), because the
  # route gate is the only thing standing between a non-admin and these
  # views. The demotion window — the gap the mount-time gate cannot
  # cover, since a socket outlives a demotion — is pinned by the
  # demote-then-click test: every write re-resolves the actor from the
  # session first. The reversal seam is system-level by design (no
  # actor-facing reversal action exists — the flagged gap), so that
  # per-event gate is the surface's own.

  use FluxValeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
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

    test "the destroy clock names the deadline, not just the start", %{conn: conn} do
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
      assert has_element?(view, "[data-testid='admin-wallet-destroy-clock']", "The clock started")
      assert has_element?(view, "[data-testid='admin-wallet-destroy-clock']", "Deletion lands")

      # The clearing is the sweep's job, never the top-up's instant:
      # the copy must not promise immediacy.
      assert has_element?(
               view,
               "[data-testid='admin-wallet-destroy-clock']",
               "clears at the next automatic check"
             )

      # The deadline is the anchor plus the sweep's 30 days: both dates
      # render, so the countdown reads as one.
      deadline_at = DateTime.add(anchored_at, 30, :day)
      deadline = Calendar.strftime(deadline_at, "%b %d, %Y")
      anchor = Calendar.strftime(anchored_at, "%b %d, %Y")

      assert text_of(view, "[data-testid='admin-wallet-destroy-clock']") =~ anchor
      assert text_of(view, "[data-testid='admin-wallet-destroy-clock']") =~ deadline

      # The runway names the depletion the member surface sees too.
      assert text_of(view, "[data-testid='wallet-runway']") =~ "Depleted"

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

    test "a recovered balance with an unswept anchor is NOT the danger state", %{
      conn: conn
    } do
      # The sweep anchors the clock when the balance first goes
      # negative and clears it hourly: a topped-up wallet can carry the
      # anchor for up to an hour. The anchor alone is not a countdown.
      {org, wallet} = funded_wallet!()

      wallet
      |> Ash.Changeset.for_update(
        :set_ladder_state,
        %{negative_since: DateTime.add(DateTime.utc_now(), -1, :hour)},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      # No danger card, no Depleted runway: the honest recovered card.
      refute has_element?(view, "[data-testid='admin-wallet-destroy-clock']")
      assert has_element?(view, "[data-testid='admin-wallet-recovered']")
      assert has_element?(view, "[data-testid='admin-wallet-recovered']", "balance recovered")

      assert has_element?(
               view,
               "[data-testid='admin-wallet-recovered']",
               "clears at the next automatic check"
             )

      assert has_element?(
               view,
               "[data-testid='admin-wallet-recovered']",
               "Nothing is on a countdown"
             )

      assert text_of(view, "[data-testid='wallet-runway']") =~ "No active burn"

      assert org
    end

    test "an unknown wallet redirects back to the table", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/billing"}}} =
               live(conn, "/admin/billing/wallets/#{Ecto.UUID.generate()}")
    end
  end

  describe "the waiver flip" do
    test "confirms with the delta copy, then flips", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      assert text_of(view, "[data-testid='admin-wallet-waiver-state']") == "Not waived"

      view
      |> element("[data-testid='admin-wallet-waiver-flip']")
      |> render_click()

      # The card carries the contract; the confirm states what changes.
      assert has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='destructive-confirm']", "has-paid gate opens")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "private access and backups unlock"
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

    test "removing the waiver from an unpaid org names what closes", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      # The setup wallet's funding is an adjustment credit: no purchase
      # rows, so the gate reads the waiver alone.
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

      assert has_element?(view, "#flash-info", "The has-paid gate closes again")
      assert text_of(view, "[data-testid='admin-wallet-waiver-state']") == "Not waived"
    end

    test "removing the waiver from a PAID org closes nothing, and says so", %{
      conn: conn,
      admin: admin
    } do
      {org, wallet} = funded_wallet!()

      # One purchase row: the has-paid gate reads the waiver OR the
      # purchase history, so the flag is not the only thing holding
      # the gate open.
      {:ok, _purchase} = Billing.credit_wallet(wallet, 100)
      {:ok, _waived} = Wallet.set_waiver(wallet, %{paywall_waived: true}, actor: admin)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      view
      |> element("[data-testid='admin-wallet-waiver-flip']")
      |> render_click()

      assert has_element?(view, "[data-testid='destructive-confirm']", "purchase history")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "nothing changes for this org"
             )

      view
      |> element("[data-testid='admin-wallet-waiver-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "keeps the has-paid gate satisfied")
      assert has_element?(view, "#flash-info", "nothing changed for this org")
      assert text_of(view, "[data-testid='admin-wallet-waiver-state']") == "Not waived"

      assert org
    end
  end

  describe "the goodwill credit" do
    test "the submit opens a confirm and nothing posts until it", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "500"}})

      # The confirm names the irreversibility and echoes the money.
      assert has_element?(view, "[data-testid='destructive-confirm']")
      assert has_element?(view, "[data-testid='destructive-confirm']", "$5.00")

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "cannot be un-posted, only reversed"
             )

      assert has_element?(view, "[data-testid='admin-wallet-goodwill-confirm']")
      assert has_element?(view, "[data-testid='admin-wallet-goodwill-cancel']")

      # Nothing moved yet: the ledger and the balance are unmoved.
      assert length(ledger_entries!(wallet, admin)) == 1
      assert text_of(view, "[data-testid='wallet-balance']") =~ "$100.00"

      # Cancel is a way out: still nothing posted.
      view
      |> element("[data-testid='admin-wallet-goodwill-cancel']")
      |> render_click()

      refute has_element?(view, "[data-testid='destructive-confirm']")
      assert length(ledger_entries!(wallet, admin)) == 1

      # This time the decisive button: the keyless post lands, the
      # row renders at the top (the operator review the domain names
      # as the guard), and the form clears.
      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "500"}})

      view
      |> element("[data-testid='admin-wallet-goodwill-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-info", "Posted $5.00 as an adjustment credit")
      assert has_element?(view, "#flash-info", "cannot be un-posted, only reversed")

      [posted | _rest] = ledger_entries!(wallet, admin)
      rows = row_ids(view)
      assert List.first(rows) == posted.id

      assert text_of(view, "[data-testid='admin-wallet-amount-#{posted.id}']") == "+$5.00"
      assert has_element?(view, "[data-testid='admin-wallet-entry-#{posted.id}']", "Adjustment")
      assert text_of(view, "[data-testid='wallet-balance']") =~ "$105.00"
      assert length(ledger_entries!(wallet, admin)) == 2

      input =
        view
        |> element("#admin-wallet-goodwill-form")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-testid='admin-wallet-goodwill-amount']")
        |> Enum.at(0)

      assert LazyHTML.attribute(input, "value") == [""]
    end

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

      assert LazyHTML.attribute(button, "phx-disable-with") == ["Reviewing..."]
    end

    test "a live dollar echo rides the input", %{conn: conn, wallet: wallet} do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      render_change(view, "goodwill-echo", %{"goodwill" => %{"amount_cents" => "500"}})

      assert text_of(view, "[data-testid='admin-wallet-goodwill-echo']") == "= $5.00"

      # A non-amount silences the echo rather than echoing junk.
      render_change(view, "goodwill-echo", %{"goodwill" => %{"amount_cents" => "abc"}})
      refute has_element?(view, "[data-testid='admin-wallet-goodwill-echo']")
    end

    test "fractional cents are refused with the honest conversion", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "5.50"}})

      assert has_element?(view, "#flash-error", "Whole cents only. Enter 550 for $5.50.")
      assert has_element?(view, "#flash-error", "Nothing was posted")

      # The typed value stays so the operator sees what they typed.
      assert has_element?(view, "[data-testid='admin-wallet-goodwill-amount']")
      entries = ledger_entries!(wallet, admin)
      assert length(entries) == 1
    end

    test "amounts over the ceiling are refused before any confirm exists", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "100_001"}})

      # Integer.parse stops at the underscore, so this shape is the
      # generic refusal.
      assert has_element?(view, "#flash-error", "whole number of US cents")

      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "100001"}})

      assert has_element?(view, "#flash-error", "Goodwill credits cap at $1000.00")
      assert has_element?(view, "#flash-error", "Nothing was posted")
      refute has_element?(view, "[data-testid='admin-wallet-goodwill-confirm']")

      entries = ledger_entries!(wallet, admin)
      assert length(entries) == 1

      # At the ceiling exactly: the confirm opens as usual.
      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "100000"}})

      assert has_element?(view, "[data-testid='admin-wallet-goodwill-confirm']")
    end

    test "an amount that is not a whole positive number of cents is refused", %{
      conn: conn,
      admin: admin
    } do
      {org, wallet} = funded_wallet!(balance_cents: 0)
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      for bad <- ["0", "-3", "abc", "", "5.505"] do
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

      # The reversal renders at the top with its neutral provenance
      # chip; the original stays in the ledger, struck and muted, its
      # lever gone.
      rows = row_ids(view)
      assert [reversal_id, original_id] = Enum.take(rows, 2)
      assert reversal_id != original.id
      assert original_id == original.id

      assert text_of(view, "[data-testid='admin-wallet-amount-#{reversal_id}']") == "-$2.50"

      assert has_element?(view, "[data-testid='admin-wallet-entry-#{reversal_id}']", "Reversal")

      assert has_element?(
               view,
               "[data-testid='admin-wallet-entry-#{original.id}'] .hero-arrow-uturn-right"
             )

      assert has_element?(view, "[data-testid='admin-wallet-entry-#{original.id}']", "Reversed")

      refute has_element?(view, "[data-testid='admin-wallet-reverse-#{original.id}']")

      # The struck amount: the netted row reads muted, not live money.
      amount_html =
        view
        |> element("[data-testid='admin-wallet-amount-#{original.id}']")
        |> render()

      assert amount_html =~ "line-through"

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

    test "a crafted id naming ANOTHER wallet's entry refuses at the reveal", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      # Wallet B carries its own funded credit; A's page must never act
      # outside the wallet it renders. (The admin MAY reverse B's entry
      # from B's own page; this is scoping, not privilege.)
      {_org_b, wallet_b} = funded_wallet!()
      {:ok, foreign} = LedgerEntry.grant_goodwill(wallet_b.id, 999, actor: admin)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      render_click(view, "open-reverse", %{"id" => foreign.id})

      assert has_element?(view, "#flash-error", "belongs to a different wallet")
      refute has_element?(view, "[data-testid='destructive-confirm']")

      # A's ledger is unmoved, and nothing on B's wallet netted or
      # changed (B carries its funding grant and the probe credit).
      assert length(ledger_entries!(wallet, admin)) == 1

      b_entries = ledger_entries!(wallet_b, admin)
      assert [] = Enum.filter(b_entries, &(&1.reverses_id != nil))

      assert admin
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

    test "load-more merges the reversed markers: a page-2 original whose reversal rode page 1 stays netted",
         %{
           conn: conn,
           admin: admin,
           wallet: wallet
         } do
      # The pair lands OLDEST (reversals sort above their originals),
      # then 24 grants fill page 1: the reversal rides page 1, its
      # original waits on page 2.
      {:ok, original} = LedgerEntry.grant_goodwill(wallet.id, 250, actor: admin)
      {:ok, _reversal} = Billing.reverse_entry(original)

      for _n <- 1..24 do
        {:ok, _grant} = Billing.grant_credits(wallet, 1, reason: :adjustment)
      end

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      # Page 1: the 24 grants plus the reversal — the original is not here.
      rows = row_ids(view)
      assert length(rows) == 25
      refute Enum.member?(rows, original.id)

      view
      |> element("[data-testid='admin-wallet-load-more']")
      |> render_click()

      # The original arrives already netted: the Reversed badge and no
      # live lever, because the page-1 reversal merged into the set.
      assert has_element?(
               view,
               "[data-testid='admin-wallet-entry-#{original.id}'] .hero-arrow-uturn-right"
             )

      refute has_element?(view, "[data-testid='admin-wallet-reverse-#{original.id}']")

      amount_html =
        view
        |> element("[data-testid='admin-wallet-amount-#{original.id}']")
        |> render()

      assert amount_html =~ "line-through"
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

    test "the reason badges keep their distinct tone and icon pairs", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      # A swap of tone or icon between reasons must fail a test: the
      # pair is the badge's identity, in both themes.
      {:ok, purchase} =
        Billing.grant_credits(wallet, 100, reason: :purchase, idempotency_key: "polar:x")

      {:ok, _usage} = Billing.debit_wallet(wallet, 10 * 10_000)
      {:ok, _refund} = Billing.reverse_entry(purchase)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      row_html = fn id ->
        render(element(view, "[data-testid='admin-wallet-entry-#{id}']"))
      end

      ledger = ledger_entries!(wallet, admin)

      # purchase: success tone, the card icon.
      purchase_html = row_html.(purchase.id)
      assert purchase_html =~ "bg-success-muted"
      assert purchase_html =~ "hero-credit-card"

      # usage: neutral tone, the chip icon.
      [usage] = Enum.filter(ledger, &(&1.reason == :usage))
      usage_html = row_html.(usage.id)
      assert usage_html =~ "bg-panel-raised"
      assert usage_html =~ "hero-cpu-chip"

      # refund: warning tone, the arrow-path icon.
      [refund] = Enum.filter(ledger, &(&1.reason == :refund))
      refund_html = row_html.(refund.id)
      assert refund_html =~ "bg-warning-muted"
      assert refund_html =~ "hero-arrow-path"

      # adjustment: dashed border (distinct from usage's solid neutral).
      [adjustment] = Enum.filter(ledger, &(&1.reason == :adjustment))
      adjustment_html = row_html.(adjustment.id)
      assert adjustment_html =~ "border-dashed"
      assert adjustment_html =~ "hero-adjustments-horizontal"
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

      assert has_element?(
               view,
               "[data-testid='admin-wallet-entry-#{welcome.id}'] .hero-sparkles"
             )
    end
  end

  describe "the confirm guards" do
    test "a second confirm click is a quiet no-op, not a crash", %{conn: conn, wallet: wallet} do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      # Confirm events with nothing open: the expired arm, all three.
      render_click(view, "confirm-waiver", %{})
      render_click(view, "confirm-reverse", %{})
      render_click(view, "confirm-goodwill", %{})

      # The page is alive and nothing happened.
      assert has_element?(view, "[data-testid='admin-wallet-detail']")
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a confirm event naming the OTHER panel is a no-op too", %{conn: conn, wallet: wallet} do
      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      view
      |> element("[data-testid='admin-wallet-waiver-flip']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-wallet-waiver-confirm']")

      # The reversal confirm arrives while the waiver panel is open:
      # stale frame, nothing to do.
      render_click(view, "confirm-reverse", %{})

      # The waiver panel stays open, the page is alive.
      assert has_element?(view, "[data-testid='admin-wallet-waiver-confirm']")
      assert has_element?(view, "[data-testid='admin-wallet-detail']")
    end
  end

  describe "the demotion window" do
    test "a mid-session demotion cannot post: every write re-resolves the actor", %{
      conn: conn,
      admin: admin,
      wallet: wallet
    } do
      {:ok, entry} = LedgerEntry.grant_goodwill(wallet.id, 100, actor: admin)

      {:ok, view, _html} = live(conn, "/admin/billing/wallets/#{wallet.id}")

      # While the session still resolves an admin, the confirms open.
      render_click(view, "open-waiver", %{})
      assert has_element?(view, "[data-testid='admin-wallet-waiver-confirm']")
      render_click(view, "cancel-confirm", %{})

      render_click(view, "open-reverse", %{"id" => entry.id})
      assert has_element?(view, "[data-testid='admin-wallet-reverse-confirm']")
      render_click(view, "cancel-confirm", %{})

      # Demote the actor under the live session. User carries no
      # role-write action and Ash.Seed is create-only, so this one
      # precondition rides the data layer directly (tests own their
      # preconditions; the write gate is what the test pins).
      query = from(u in "users", where: u.id == ^Ecto.UUID.dump!(admin.id))
      {updated, nil} = FluxVale.Repo.update_all(query, set: [platform_role: "user"])
      assert updated == 1

      # Each refusal clears the one-open confirm, so each write
      # re-reveals first (the reveals are reads; the writes are the
      # gate).
      render_click(view, "open-reverse", %{"id" => entry.id})

      view
      |> element("[data-testid='admin-wallet-reverse-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Your admin access ended")

      entries = ledger_entries!(wallet, admin)
      assert [] = Enum.filter(entries, &(&1.reverses_id == entry.id))

      render_click(view, "open-waiver", %{})

      view
      |> element("[data-testid='admin-wallet-waiver-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Your admin access ended")

      {:ok, fresh} = Wallet.get_by_organization(wallet.organization_id, actor: admin)
      assert fresh.paywall_waived == false

      view
      |> element("#admin-wallet-goodwill-form")
      |> render_submit(%{"goodwill" => %{"amount_cents" => "300"}})

      assert has_element?(view, "[data-testid='admin-wallet-goodwill-confirm']")

      view
      |> element("[data-testid='admin-wallet-goodwill-confirm']")
      |> render_click()

      assert has_element?(view, "#flash-error", "Your admin access ended")

      # The ledger holds exactly what it held before the demotion:
      # the funding grant and the pre-seeded goodwill entry.
      assert length(ledger_entries!(wallet, admin)) == 2
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
