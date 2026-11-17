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
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  setup %{conn: conn} do
    user = AccountsFixtures.user!()

    # S5: the personal org no longer renders org pages (its URL
    # redirects to /billing) — the org-billing tests ride a real org the
    # actor owns. The fixture org has no JIT welcome grant, so the
    # balance starts at exactly zero: the tests below own their
    # arithmetic.
    org = AccountsFixtures.owned_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)

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

  # S9: the band is the org's wallet — the org's name rides the
  # eyebrow, the facts are the same in-band pair the personal page
  # shows (no instances → no burn → the infinite-runway arm).
  test "the band carries the org identity and the wallet facts", %{
    conn: conn,
    org: org,
    wallet: wallet
  } do
    {:ok, _grant} = Billing.grant_credits(wallet, 10_000)

    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    assert has_element?(view, "[data-testid='wallet-balance']", "$100.00")
    assert has_element?(view, "[data-testid='wallet-runway']", "No active burn")
    assert has_element?(view, "[data-testid='wallet-runway']", "Nothing burning right now.")
  end

  test "the switcher names the viewed org as the active context", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    assert has_element?(view, "[data-testid='org-switcher-button']", org.name)
  end

  test "the Top up wallet CTA opens the org-scoped wizard", %{conn: conn, org: org} do
    {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    # The wizard this CTA opens bills THIS org's wallet (#408) — the
    # org-scoped route, not the personal one.
    assert has_element?(
             view,
             "a#add-credits[href='/organizations/#{org.slug}/billing/topup']",
             "Top up wallet"
           )
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

  test "the page bills the URL org — same actor, two orgs", %{
    conn: conn,
    user: user,
    org: org,
    wallet: wallet
  } do
    # The discriminating case: the SAME actor belongs to two orgs, so
    # "the URL's org" and "the actor's other org" are different rows and
    # the page must bill whichever the URL names. No flow creates a
    # second org or a second membership yet (team features are future),
    # so both rows ride the actions with authorize?: false — the
    # sanctioned bootstrap posture (the #279 membership precondition).
    team_org = Organization.create!(%{name: "Team Org", slug: "team-org"}, authorize?: false)
    {:ok, team_wallet} = Billing.ensure_wallet(team_org)

    Membership.create!(%{organization_id: team_org.id, user_id: user.id, role: :owner},
      authorize?: false
    )

    {:ok, _grant} = Billing.grant_credits(team_wallet, 22_200)
    {:ok, _grant} = Billing.grant_credits(wallet, 11_100)

    # The team page bills the team wallet: its balance and its row show,
    # the setup org's row never leaks in.
    {:ok, team_view, _html} = live(conn, ~p"/organizations/#{team_org.slug}/billing")

    assert has_element?(team_view, "[data-testid='wallet-balance']", "$222.00")
    assert has_element?(team_view, "[data-testid='ledger-row']", "+$222.00")
    refute has_element?(team_view, "[data-testid='ledger-row']", "+$111.00")

    # And the setup org's page is the mirror image.
    {:ok, org_view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

    assert has_element?(org_view, "[data-testid='wallet-balance']", "$111.00")
    assert has_element?(org_view, "[data-testid='ledger-row']", "+$111.00")
    refute has_element?(org_view, "[data-testid='ledger-row']", "+$222.00")
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

  # ── The auto-recharge card (#829 L3, the launch shape) ──

  describe "the auto-recharge card" do
    test "a mount ensures the row: a fresh org renders OFF and the row exists", %{
      conn: conn,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "[data-testid='auto-recharge-card']")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")

      # The provisioning seam ran at mount: the owner's first write is
      # :set (an UPDATE), so the row must exist even though nothing
      # rendered it before. authorize?: false — asserting STORAGE (the
      # paper-trail posture).
      assert {:ok, %AutoRechargeSetting{mode: :off}} =
               Billing.get_auto_recharge_setting(org.id, authorize?: false)
    end

    test "two mounts, one row — the unique_org backstop holds", %{conn: conn, org: org} do
      {:ok, _first, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")
      {:ok, _second, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      rows =
        AutoRechargeSetting
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 1
    end

    test "the owner sees the form; a member sees only the read-only state", %{
      conn: conn,
      org: org
    } do
      {:ok, owner_view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(owner_view, "#auto-recharge-form")
      assert has_element?(owner_view, "select[data-testid='auto-recharge-mode']")

      # The colleague with a plain :member seat: the state is theirs to
      # read, the form is not theirs to touch.
      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      member_conn = SessionHelpers.sign_in(Phoenix.ConnTest.build_conn(), member)

      {:ok, member_view, _html} = live(member_conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(member_view, "[data-testid='auto-recharge-state']", "Reminders are off")
      refute has_element?(member_view, "#auto-recharge-form")
      assert has_element?(member_view, "[data-testid='auto-recharge-member-hint']")
    end

    test ":auto is not an offered mode — the form offers reminders only", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "select[data-testid='auto-recharge-mode'] option[value='off']")
      assert has_element?(view, "#auto-recharge-form option[value='reminder']")
      refute has_element?(view, "#auto-recharge-form option[value='auto']")
    end

    test "the owner enables reminders — the card reads ON and the row persists", %{
      conn: conn,
      org: org,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "10",
          "amount_dollars" => "25"
        }
      })

      assert has_element?(view, "#flash-info", "Reminder settings saved.")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders on")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "below $10")
      assert has_element?(view, "[data-testid='auto-recharge-amount']", "$25")

      # Persisted, not just displayed — re-read through the domain seam.
      assert {:ok, setting} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert setting.mode == :reminder
      assert setting.threshold_cents == 1_000
      assert setting.amount_cents == 2_500
    end

    test "typing survives the validate round-trip", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_change(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "7",
          "amount_dollars" => "30"
        }
      })

      assert has_element?(view, "input#auto_recharge_threshold_dollars[value='7']")
      assert has_element?(view, "input#auto_recharge_amount_dollars[value='30']")
    end

    test "a threshold below $1 is rejected and nothing persists", %{
      conn: conn,
      org: org,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "0",
          "amount_dollars" => "25"
        }
      })

      assert has_element?(
               view,
               "#flash-error",
               "The threshold must be a whole-dollar amount of at least $1."
             )

      assert {:ok, setting} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert setting.mode == :off
    end

    test "an amount below the top-up floor is rejected and nothing persists", %{
      conn: conn,
      org: org,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")
      floor = Billing.min_topup_dollars()

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "10",
          "amount_dollars" => Integer.to_string(floor - 1)
        }
      })

      assert has_element?(
               view,
               "#flash-error",
               "The amount must be a whole-dollar amount of at least $#{floor}."
             )

      assert {:ok, setting} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert setting.mode == :off
    end

    test "a crafted :auto submit fails the domain's validation — a flash error, not a crash", %{
      conn: conn,
      org: org,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25"
        }
      })

      assert has_element?(view, "#flash-error", "Couldn't save the reminder settings.")
      assert {:ok, setting} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert setting.mode == :off
    end

    test "a member's crafted submit is forbidden at the domain seam — a flash error, not a crash",
         %{conn: _conn, org: org, user: user} do
      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      member_conn = SessionHelpers.sign_in(Phoenix.ConnTest.build_conn(), member)
      {:ok, member_view, _html} = live(member_conn, ~p"/organizations/#{org.slug}/billing")

      render_click(member_view, "save-auto-recharge", %{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "10",
          "amount_dollars" => "25"
        }
      })

      assert has_element?(member_view, "#flash-error", "Couldn't save the reminder settings.")
      assert {:ok, setting} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert setting.mode == :off
    end

    test "a non-round stored threshold renders exact cents, not a floored dollar", %{
      conn: conn,
      org: org,
      user: user
    } do
      # threshold_cents is an owner-settable integer ≥ 100¢, so 550¢ is
      # a legal row the form's whole-dollar unit cannot type — the L2
      # mailer's exact-cents rule applies to the card's copy too. The
      # write rides the domain seam (a legal :set input).
      {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

      assert {:ok, _set} =
               Billing.set_auto_recharge_setting(
                 setting,
                 %{mode: :reminder, threshold_cents: 549},
                 actor: user
               )

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "[data-testid='auto-recharge-state']", "below $5.49")
      refute has_element?(view, "[data-testid='auto-recharge-state']", "below $5 —")
    end

    test "a crafted submit missing the fields is rejected", %{conn: conn, org: org} do
      # A raw event push, not a form submit — the DOM inputs always
      # merge their values into a submit, so the missing-fields shape
      # is a crafted event's shape (the whole_dollars nil arm).
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      render_click(view, "save-auto-recharge", %{"auto_recharge" => %{"mode" => "reminder"}})

      assert has_element?(view, "#flash-error", "at least $1.")
    end

    test "turning reminders off again reads OFF", %{conn: conn, org: org, user: user} do
      {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

      assert {:ok, _on} =
               Billing.set_auto_recharge_setting(setting, %{mode: :reminder}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "off",
          "threshold_dollars" => "5",
          "amount_dollars" => "25"
        }
      })

      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")
      refute has_element?(view, "[data-testid='auto-recharge-amount']")
      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.mode == :off
    end
  end
end
