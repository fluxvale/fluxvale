defmodule FluxValeWeb.OrganizationLive.BillingTest do
  @moduledoc false

  # The org billing view (#276): the /billing shape scoped to the URL's
  # org — balance and ledger for THAT org only, the not-found arm for
  # unknown slugs and non-members alike, and the "Load more" keyset
  # walk (mirrors BillingLive.IndexTest).

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Providers.Polar
  alias FluxVale.Billing.Topup
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

    test "a non-round stored value renders exact cents and prefills EMPTY", %{
      conn: conn,
      org: org,
      user: user
    } do
      # threshold_cents/amount_cents are owner-settable integers above
      # their floors, so 549¢ rows are legal values the form's
      # whole-dollar unit cannot type — the L2 mailer's exact-cents
      # rule applies to the card's copy, and the form must NOT prefill
      # "5": an unedited save would silently floor 549¢ to 500¢. The
      # write rides the domain seam (a legal :set input).
      {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

      assert {:ok, _set} =
               Billing.set_auto_recharge_setting(
                 setting,
                 %{mode: :reminder, threshold_cents: 549, amount_cents: 549},
                 actor: user
               )

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "[data-testid='auto-recharge-state']", "below $5.49")
      refute has_element?(view, "[data-testid='auto-recharge-state']", "below $5 —")

      # The inputs prefill EMPTY (never a floored figure) and the hints
      # name the stored exact values.
      assert has_element?(view, "input#auto_recharge_threshold_dollars[value='']")
      assert has_element?(view, "input#auto_recharge_amount_dollars[value='']")
      assert has_element?(view, "[data-testid='auto-recharge-threshold-hint']", "Stored: $5.49")
      assert has_element?(view, "[data-testid='auto-recharge-amount-hint']", "Stored: $5.49")

      # An unedited save (both empty) fails the whole-dollar validation
      # and leaves the stored row untouched.
      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "",
          "amount_dollars" => ""
        }
      })

      assert has_element?(view, "#flash-error", "at least $1.")

      assert {:ok, unchanged} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert unchanged.threshold_cents == 549
      assert unchanged.amount_cents == 549
      assert unchanged.mode == :reminder

      # A half-filled save fails on the still-empty field.
      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "6",
          "amount_dollars" => ""
        }
      })

      assert has_element?(view, "#flash-error", "at least $#{Billing.min_topup_dollars()}.")
      assert {:ok, still} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert still.amount_cents == 549
    end

    test "a member's crafted validate event cannot resurrect the form", %{conn: _conn, org: org} do
      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      member_conn = SessionHelpers.sign_in(Phoenix.ConnTest.build_conn(), member)
      {:ok, member_view, _html} = live(member_conn, ~p"/organizations/#{org.slug}/billing")

      render_click(member_view, "validate-auto-recharge", %{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "3",
          "amount_dollars" => "10"
        }
      })

      # The view survives and stays formless — the gate is the card's,
      # not just the mount's.
      assert has_element?(member_view, "[data-testid='auto-recharge-state']", "Reminders are off")
      refute has_element?(member_view, "#auto-recharge-form")
      assert has_element?(member_view, "[data-testid='auto-recharge-member-hint']")
    end

    test "a crafted non-map payload is a no-op, never a crash", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      render_click(view, "validate-auto-recharge", %{"auto_recharge" => "x"})
      assert has_element?(view, "[data-testid='auto-recharge-card']")

      render_click(view, "save-auto-recharge", %{"auto_recharge" => "x"})
      assert has_element?(view, "[data-testid='auto-recharge-card']")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")
    end

    test "a crafted submit missing the fields is rejected", %{conn: conn, org: org} do
      # A raw event push, not a form submit — the DOM inputs always
      # merge their values into a submit, so the missing-fields shape
      # is a crafted event's shape (the whole_dollars nil arm).
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      render_click(view, "save-auto-recharge", %{"auto_recharge" => %{"mode" => "reminder"}})

      assert has_element?(view, "#flash-error", "at least $1.")
    end

    test "crafted non-scalar values render without raising (validate and save)", %{
      conn: conn,
      org: org
    } do
      # Nested maps/lists ride is_map(params) and would raise
      # Phoenix.HTML.Safe at render (options_for_select / number inputs
      # take strings) — the form filters to binary values, and the save
      # path answers a crafted non-scalar mode through the domain's
      # enum as a flash error.
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      render_click(view, "validate-auto-recharge", %{
        "auto_recharge" => %{
          "mode" => %{"deep" => "x"},
          "threshold_dollars" => %{"nested" => "map"},
          "amount_dollars" => ["a", "b"]
        }
      })

      assert has_element?(view, "[data-testid='auto-recharge-card']")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")

      render_click(view, "save-auto-recharge", %{
        "auto_recharge" => %{
          "mode" => %{"deep" => "x"},
          "threshold_dollars" => ["a"],
          "amount_dollars" => 5
        }
      })

      assert has_element?(view, "#flash-error", "Couldn't save the reminder settings.")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")
    end

    test "disabling reminders is a mode-only save — a non-round row needs no dollar input", %{
      conn: conn,
      org: org,
      user: user
    } do
      # 549¢ prefills EMPTY (never-floor), so an off save that demanded
      # whole-dollar figures would force the owner to re-enter stored
      # values just to switch reminders off. Mode-only: stored cents
      # survive untouched.
      {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

      assert {:ok, _set} =
               Billing.set_auto_recharge_setting(
                 setting,
                 %{mode: :reminder, threshold_cents: 549, amount_cents: 549},
                 actor: user
               )

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{"auto_recharge" => %{"mode" => "off"}})

      assert has_element?(view, "#flash-info", "Reminder settings saved.")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")
      refute has_element?(view, "[data-testid='auto-recharge-amount']")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.mode == :off
      assert persisted.threshold_cents == 549
      assert persisted.amount_cents == 549
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

  # ── The staged charge card (S5) ──
  #
  # Everything chargey exists only when the gate reads true. The gate
  # rides a stub of Billing.auto_recharge_charge_mode?/0 — never an
  # app-env mutation (async suites share the node's env; the S4 sweep's
  # posture). Provider legs ride Mimic canaries (the topup_org_test
  # stance): the session opens in the LiveView process, so stub (not
  # expect) and assert the request through a message. NO live Polar
  # call exists in this lane.

  @launch_testids ~w(auto-recharge-card auto-recharge-state auto-recharge-form auto-recharge-mode auto-recharge-threshold auto-recharge-amount-input auto-recharge-save)

  @chargey_testids ~w(auto-recharge-method auto-recharge-method-status add-payment-method auto-recharge-method-hint auto-recharge-activity auto-recharge-activity-empty auto-recharge-activity-row auto-recharge-charge-fields auto-recharge-cap auto-recharge-strikes auto-recharge-country auto-recharge-state-input auto-recharge-customer-type auto-recharge-vat auto-recharge-arm-confirm auto-recharge-arm-math auto-recharge-disabled)

  describe "the charge card, gate OFF (the parity pin)" do
    setup do
      stub(Billing, :auto_recharge_charge_mode?, fn -> false end)
      :ok
    end

    test "the card renders the launch testids and NOTHING more", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      Enum.each(@launch_testids, fn testid ->
        assert has_element?(view, "[data-testid='#{testid}']")
      end)

      Enum.each(@chargey_testids, fn testid ->
        refute has_element?(view, "[data-testid='#{testid}']")
      end)

      # The launch select: off + reminder, never :auto.
      assert has_element?(view, "#auto-recharge-form option[value='off']")
      assert has_element?(view, "#auto-recharge-form option[value='reminder']")
      refute has_element?(view, "#auto-recharge-form option[value='auto']")
    end

    test "the add-method event is refused — no provider call, no crash", %{conn: conn, org: org} do
      parent = self()

      stub(Polar, :create_billing_session, fn _request, _opts ->
        send(parent, :provider_called_with_gate_off)
        flunk("no provider call with the gate off")
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      render_click(view, "add-payment-method", %{})

      assert has_element?(view, "[data-testid='auto-recharge-card']")
      refute_received(:provider_called_with_gate_off)
    end

    test "a crafted gate-off save carrying charge fields writes none of them", %{
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
          "amount_dollars" => "25",
          "daily_charge_cap" => "6",
          "failure_strikes" => "5",
          "billing_country" => "US",
          "customer_type" => "business"
        }
      })

      assert has_element?(view, "#flash-info", "Reminder settings saved.")

      # The gate-off save stays L3's shape: the charge fields are not
      # part of the launch write.
      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.daily_charge_cap == 2
      assert persisted.failure_strikes == 3
      assert is_nil(persisted.billing_country)
      assert persisted.customer_type == :consumer
    end
  end

  describe "the charge card, gate ON" do
    setup %{conn: conn, user: user, org: org} do
      stub(Billing, :auto_recharge_charge_mode?, fn -> true end)
      {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

      %{setting: setting, owner_email: AccountsFixtures.primary_address!(user)}
    end

    # System write — :set_method_status is actor-forbidden by policy;
    # the tests drive it the way the production seam does.
    defp link_customer!(setting, customer_id \\ "cust_test") do
      setting
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :none,
        provider_customer_id: customer_id
      })
      |> Ash.update!(authorize?: false)
    end

    defp attach_method!(setting, customer_id \\ "cust_test") do
      setting
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: customer_id
      })
      |> Ash.update!(authorize?: false)
    end

    defp save_evidence!(setting, owner) do
      {:ok, setting} =
        Billing.set_auto_recharge_setting(
          setting,
          %{billing_country: "US", billing_state: "CA"},
          actor: owner
        )

      setting
    end

    defp auto_topup!(org, amount_cents, status) do
      {:ok, topup} =
        Topup.create(
          %{organization_id: org.id, amount_cents: amount_cents, origin: :auto},
          authorize?: false
        )

      case status do
        :pending ->
          topup

        other ->
          update = if(other == :completed, do: :mark_completed, else: :mark_failed)

          topup
          |> Ash.Changeset.for_update(update, %{})
          |> Ash.update!(authorize?: false)
      end
    end

    test "the method block renders — no customer yet, button disabled without evidence", %{
      conn: conn,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "[data-testid='auto-recharge-method']")
      assert has_element?(view, "[data-testid='auto-recharge-method-status']", "None saved yet")
      assert has_element?(view, "button[data-testid='add-payment-method'][disabled]")
      assert has_element?(view, "[data-testid='auto-recharge-method-hint']")

      # The charge form fields are present for the owner (gate-on), and
      # the activity list renders its empty state.
      assert has_element?(view, "[data-testid='auto-recharge-charge-fields']")
      assert has_element?(view, "[data-testid='auto-recharge-activity']")
      assert has_element?(view, "[data-testid='auto-recharge-activity-empty']", "No auto top-ups")
    end

    test "a saved method + a linked customer read honestly", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      attach_method!(setting)
      save_evidence!(setting, user)

      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "[data-testid='auto-recharge-method-status']", "Saved")

      # No hint on an enabled button, and no disabled attribute.
      refute has_element?(view, "button[data-testid='add-payment-method'][disabled]")
    end

    test "the add-method click mints the session, persists the customer ref, redirects", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user,
      owner_email: owner_email
    } do
      save_evidence!(setting, user)
      parent = self()

      stub(Polar, :create_billing_session, fn request, _opts ->
        send(parent, {:session_request, request})
        {:ok, %{customer_id: "cust_first", portal_url: "https://portal.example/one-time"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert {:error, {:redirect, %{to: "https://portal.example/one-time"}}} =
               render_click(view, "add-payment-method", %{})

      # The request carried the OWNER'S primary verified email and the
      # SETTING'S evidence address.
      assert_received {:session_request, request}
      assert request.email == owner_email
      assert request.organization_id == org.id
      assert request.billing_address == %{country: "US", state: "CA"}

      # The customer reference persisted; the status stays :none — a
      # customer is not a method (the mount sync answers that).
      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
      assert persisted.provider_customer_id == "cust_first"
      assert persisted.payment_method_status == :none
    end

    test "a second click mints a FRESH session — never a stored URL", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      save_evidence!(setting, user)

      counter = :counters.new(1, [:atomics])

      stub(Polar, :create_billing_session, fn _request, _opts ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        {:ok, %{customer_id: "cust_#{n}", portal_url: "https://portal.example/#{n}"}}
      end)

      stub(Polar, :list_payment_methods, fn _id -> {:ok, 0, nil} end)

      # Click one: its own mint, redirect off-site.
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert {:error, {:redirect, %{to: "https://portal.example/1"}}} =
               render_click(view, "add-payment-method", %{})

      # The buyer returns; the next click (a fresh mount) mints AGAIN.
      {:ok, view2, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert {:error, {:redirect, %{to: "https://portal.example/2"}}} =
               render_click(view2, "add-payment-method", %{})

      # The stored reference is the LATEST session's customer.
      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
      assert persisted.provider_customer_id == "cust_2"
    end

    test "the click without evidence refuses at the seam — the hint flash, no provider call", %{
      conn: conn,
      org: org
    } do
      parent = self()

      stub(Polar, :create_billing_session, fn _request, _opts ->
        send(parent, :provider_called_without_evidence)
        flunk("no provider call without the evidence country")
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      # The button renders disabled; a crafted click still fires the
      # event — the seam is the authority.
      render_click(view, "add-payment-method", %{})

      assert has_element?(view, "#flash-error", "billing country")
      refute_received(:provider_called_without_evidence)
    end

    test "a provider fault flashes honestly", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      setting = save_evidence!(setting, user)
      stub(Polar, :create_billing_session, fn _request, _opts -> {:error, :api_error} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      render_click(view, "add-payment-method", %{})

      assert has_element?(view, "#flash-error", "Couldn't open the payment portal.")
    end

    test "the mount sync attaches on count > 0", %{conn: conn, org: org, setting: setting} do
      link_customer!(setting)
      parent = self()

      stub(Polar, :list_payment_methods, fn customer_id ->
        send(parent, {:methods_request, customer_id})
        {:ok, 1, "pm_default"}
      end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert_received {:methods_request, "cust_test"}
      assert has_element?(view, "[data-testid='auto-recharge-method-status']", "Saved")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
      assert persisted.payment_method_status == :attached
    end

    test "the mount sync un-attaches on count 0", %{conn: conn, org: org, setting: setting} do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 0, nil} end)

      {:ok, _view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
      assert persisted.payment_method_status == :none
    end

    test "a sync fault leaves the stored state untouched (the next mount retries)", %{
      conn: conn,
      org: org,
      setting: setting
    } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:error, :network_error} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "[data-testid='auto-recharge-method-status']", "Saved")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
      assert persisted.payment_method_status == :attached
    end

    test "the charge settings save persists dials + evidence through the domain seam", %{
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
          "amount_dollars" => "25",
          "daily_charge_cap" => "4",
          "failure_strikes" => "5",
          "billing_country" => "US",
          "billing_state" => "CA",
          "customer_type" => "business",
          "vat_number" => "GB12345678"
        }
      })

      assert has_element?(view, "#flash-info", "Reminder settings saved.")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.daily_charge_cap == 4
      assert persisted.failure_strikes == 5
      assert persisted.billing_country == "US"
      assert persisted.billing_state == "CA"
      assert persisted.customer_type == :business
      assert persisted.vat_number == "GB12345678"
    end

    test "the charge dials' bounds are rejected and nothing persists", %{
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
          "amount_dollars" => "25",
          "daily_charge_cap" => "7",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "#flash-error", "Max charges per day must be between 1 and 6.")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "1"
        }
      })

      assert has_element?(view, "#flash-error", "The decline limit must be between 2 and 5.")

      # A crafted save missing the dials entirely is rejected too (the
      # non-binary arm) — the DOM always carries them on a real submit.
      render_click(view, "save-auto-recharge", %{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "10",
          "amount_dollars" => "25"
        }
      })

      assert has_element?(view, "#flash-error", "Max charges per day")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.daily_charge_cap == 2
      assert persisted.failure_strikes == 3
      assert persisted.mode == :off
    end

    test "the evidence prefills from the last completed top-up only where the setting is empty",
         %{
           conn: conn,
           org: org,
           setting: setting,
           user: user
         } do
      # A completed top-up carrying buyer evidence (system writes — the
      # row's lifecycle is gateway-verified in production).
      {:ok, topup} =
        Topup.create(
          %{
            organization_id: org.id,
            amount_cents: 2_500,
            billing_country: "DE",
            vat_number: "DE123456789"
          },
          authorize?: false
        )

      topup
      |> Ash.Changeset.for_update(:mark_completed, %{})
      |> Ash.update!(authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      # Empty setting fields fall back to the completed top-up; the
      # dials and customer_type read the stored row.
      assert has_element?(view, "input#auto_recharge_billing_country[value='DE']")
      assert has_element?(view, "input#auto_recharge_vat_number[value='DE123456789']")
      assert has_element?(view, "input#auto_recharge_billing_state[value='']")
      assert has_element?(view, "select#auto_recharge_customer_type")
      assert has_element?(view, "input#auto_recharge_daily_charge_cap[value='2']")

      # The setting's OWN value wins when set — the copy-as-default
      # never overwrites stored values.
      assert {:ok, _us} =
               Billing.set_auto_recharge_setting(setting, %{billing_country: "US"}, actor: user)

      {:ok, second_view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(second_view, "input#auto_recharge_billing_country[value='US']")
      assert has_element?(second_view, "input#auto_recharge_vat_number[value='DE123456789']")
    end

    test "the :auto option appears only with a method attached", %{
      conn: conn,
      org: org,
      setting: setting
    } do
      # No method yet: the select mirrors the AutoArmGate's refusal.
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")
      refute has_element?(view, "#auto-recharge-form option[value='auto']")

      # Method attached (and the mount sync agrees).
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, armed_view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")
      assert has_element?(armed_view, "#auto-recharge-form option[value='auto']")
    end

    test "arming without confirm does not set it — the save opens the confirm step", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      # The confirm step shows, with the gross math named from the
      # stored values.
      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")
      assert has_element?(view, "[data-testid='auto-recharge-arm-math']")
      assert has_element?(view, "[data-testid='auto-recharge-arm-math']", "$50")

      # Nothing armed yet.
      assert {:ok, setting} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert setting.mode == :off
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")
    end

    test "save-and-stage persists the edited dials BEFORE the confirm opens", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "50",
          "daily_charge_cap" => "4",
          "failure_strikes" => "3"
        }
      })

      # The dials the owner typed persisted as a normal write — the
      # confirm's copy is truthful about them ($200 = 4 × $50 at 0% VAT).
      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")
      assert has_element?(view, "[data-testid='auto-recharge-arm-math']", "$200")

      assert {:ok, staged} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert staged.amount_cents == 5_000
      assert staged.daily_charge_cap == 4
      # The mode write belongs to the confirm alone.
      assert staged.mode == :off
    end

    test "the confirm action arms — the only event that writes :auto", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      view
      |> element("#arm-auto-confirm")
      |> render_click()

      assert has_element?(view, "#flash-info", "Auto charging armed.")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Auto charging armed")
      refute has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.mode == :auto
    end

    test "the arming write is bound to the stored terms — a co-edit refuses and re-renders", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      # The two-tab shape: another tab saves a new amount AFTER this
      # tab's confirm rendered.
      {:ok, fresh} = Billing.get_auto_recharge_setting(org.id, authorize?: false)

      assert {:ok, _co_edit} =
               Billing.set_auto_recharge_setting(fresh, %{amount_cents: 5_000}, actor: user)

      # This tab's confirm still carries the old snapshot — refused,
      # never armed over unseen terms.
      view
      |> element("#arm-auto-confirm")
      |> render_click()

      assert has_element?(
               view,
               "#flash-error",
               "The charge settings changed — review them and confirm again."
             )

      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      assert {:ok, not_armed} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert not_armed.mode == :off

      # A crafted click with no snapshot refuses the same way.
      render_click(view, "confirm-arm-auto", %{})
      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")
      assert {:ok, still_off} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert still_off.mode == :off

      # The re-rendered confirm carries the fresh terms — the next
      # click arms exactly what is displayed.
      view
      |> element("#arm-auto-confirm")
      |> render_click()

      assert has_element?(view, "#flash-info", "Auto charging armed.")
      assert {:ok, armed} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert armed.mode == :auto
    end

    test "a non-arming save closes the confirm step — the stale click cannot arm", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      # The owner's last explicit choice was NOT auto: a reminder save
      # closes the step.
      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "#flash-info", "Reminder settings saved.")
      refute has_element?(view, "[data-testid='auto-recharge-arm-confirm']")
      refute has_element?(view, "#arm-auto-confirm")

      # A stale confirm event (crafted raw push — the button is gone
      # from the DOM) is silence: the guard answers, never an arm.
      render_click(view, "confirm-arm-auto", %{})

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.mode == :reminder
    end

    test "a methodless crafted :auto save rides the normal path — no confirm, domain refusal", %{
      conn: conn,
      org: org,
      setting: setting,
      user: user
    } do
      # No method attached: the confirm step would claim a saved card
      # the AutoArmGate would refuse — it never opens.
      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      refute has_element?(view, "[data-testid='auto-recharge-arm-confirm']")
      assert has_element?(view, "#flash-error", "Couldn't save the reminder settings.")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.mode == :off
    end

    test "a gate flip between the confirm render and the click dies at the domain — an error flash, never a write",
         %{
           conn: conn,
           org: org,
           setting: setting,
           user: user
         } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      # The platform gate flips (the S6 boundary is a config flip) —
      # the AutoArmGate answers the confirm with a refusal.
      stub(Billing, :auto_recharge_charge_mode?, fn -> false end)

      view
      |> element("#arm-auto-confirm")
      |> render_click()

      assert has_element?(view, "#flash-error", "Couldn't arm auto charging.")
      refute has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.mode == :off
    end

    test "cancel returns without arming", %{conn: conn, org: org, setting: setting, user: user} do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "10",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      view
      |> element("#arm-auto-cancel")
      |> render_click()

      refute has_element?(view, "[data-testid='auto-recharge-arm-confirm']")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, actor: user)
      assert persisted.mode == :off
    end

    test "recent activity renders the 3 most recent :auto rows; :manual never appears", %{
      conn: conn,
      org: org
    } do
      auto_topup!(org, 100, :completed)
      auto_topup!(org, 200, :failed)
      auto_topup!(org, 300, :pending)
      auto_topup!(org, 400, :completed)

      # A wizard row: money history, but NOT auto activity.
      {:ok, _manual} =
        Topup.create(%{organization_id: org.id, amount_cents: 99_900}, authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      # The three NEWEST auto rows, with their statuses and net amounts.
      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "$4")
      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "Completed")
      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "$3")
      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "Pending")
      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "$2")
      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "Failed")

      # The oldest auto row fell off the window; the manual row never
      # enters the list at all.
      refute has_element?(view, "[data-testid='auto-recharge-activity-row']", "$1")
      refute has_element?(view, "[data-testid='auto-recharge-activity-row']", "$999")
    end

    test "a disable reason renders an honest line naming why", %{
      conn: conn,
      org: org,
      setting: setting
    } do
      setting
      |> Ash.Changeset.for_update(:disable_with_reason, %{disabled_reason: :no_method})
      |> Ash.update!(authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(
               view,
               "[data-testid='auto-recharge-disabled']",
               "no saved payment method"
             )
    end

    test "a member is read-only everywhere — crafted charge events are refused", %{
      conn: _conn,
      org: org,
      setting: setting
    } do
      member = AccountsFixtures.user!()

      Membership.create!(%{organization_id: org.id, user_id: member.id, role: :member},
        authorize?: false
      )

      member_conn = SessionHelpers.sign_in(Phoenix.ConnTest.build_conn(), member)

      # A method is attached — the richest member view still shows no
      # owner affordances.
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      parent = self()

      stub(Polar, :create_billing_session, fn _request, _opts ->
        send(parent, :member_triggered_provider_call)
        flunk("no provider call from a member's view")
      end)

      {:ok, view, _html} = live(member_conn, ~p"/organizations/#{org.slug}/billing")

      assert has_element?(view, "[data-testid='auto-recharge-method-status']")
      assert has_element?(view, "[data-testid='auto-recharge-activity']")
      assert has_element?(view, "[data-testid='auto-recharge-member-hint']")

      refute has_element?(view, "[data-testid='add-payment-method']")
      refute has_element?(view, "#auto-recharge-form")
      refute has_element?(view, "[data-testid='auto-recharge-charge-fields']")
      refute has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      # The crafted events are silence — no provider call, no write.
      render_click(view, "add-payment-method", %{})
      refute_received(:member_triggered_provider_call)

      render_click(view, "confirm-arm-auto", %{})

      assert has_element?(view, "[data-testid='auto-recharge-card']")
      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org.id, authorize?: false)
      assert persisted.mode == :off
    end
  end
end
