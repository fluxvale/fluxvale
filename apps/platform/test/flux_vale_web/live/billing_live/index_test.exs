defmodule FluxValeWeb.BillingLive.IndexTest do
  @moduledoc false

  # The billing surface (#123): balance as USD from integer cents, the
  # signed ledger rows, the add-credits placeholder, and the "Load more"
  # keyset walk. No K8s, no mail — pure reads over the wallet policies.

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Providers.Polar
  alias FluxVale.Billing.Topup
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

  test "top up wallet opens the top-up wizard (#137)", %{conn: conn} do
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
    # produce, the documented seed! exception). attach_primary_email!
    # gives the row the create path would have (#287: the users table
    # carries no address; #285 T3 resolves identity through the table).
    n = System.unique_integer()
    orgless = Ash.Seed.seed!(User, %{username: "orgless-#{n}"})

    AccountsFixtures.attach_primary_email!(orgless, "orgless-#{n}@fluxvale.test")

    conn = SessionHelpers.sign_in(conn, orgless)

    case live(conn, ~p"/billing") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end

  # ── The auto-recharge card (#829 L3, the launch shape) — the
  # personal surface of the shape the org billing page shares. ──

  describe "the auto-recharge card" do
    test "the card renders between the band and the ledger, with the owner form", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "[data-testid='auto-recharge-card']")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")

      # The personal surface's actor owns their personal org, so the
      # form is here — computed by the gate, never assumed.
      assert has_element?(view, "#auto-recharge-form")
    end

    test "a mount ensures the row for the personal org", %{conn: conn, wallet: wallet} do
      {:ok, _view, _html} = live(conn, ~p"/billing")

      assert {:ok, %AutoRechargeSetting{organization_id: org_id, mode: :off}} =
               Billing.get_auto_recharge_setting(wallet.organization_id, authorize?: false)

      assert org_id == wallet.organization_id
    end

    test "enabling reminders persists on the personal org", %{conn: conn, wallet: wallet} do
      {:ok, view, _html} = live(conn, ~p"/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "2",
          "amount_dollars" => "10"
        }
      })

      assert has_element?(view, "#flash-info", "Reminder settings saved.")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders on")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "below $2")
      assert has_element?(view, "[data-testid='auto-recharge-amount']", "$10")

      # Persisted, not just displayed — re-read through the domain seam.
      assert {:ok, setting} =
               Billing.get_auto_recharge_setting(wallet.organization_id, authorize?: false)

      assert setting.mode == :reminder
      assert setting.threshold_cents == 200
      assert setting.amount_cents == 1_000
    end

    test "typing survives the validate round-trip", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing")

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

    test "a crafted :auto submit fails the domain's validation — a flash error, not a crash", %{
      conn: conn,
      wallet: wallet
    } do
      {:ok, view, _html} = live(conn, ~p"/billing")

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

      assert {:ok, setting} =
               Billing.get_auto_recharge_setting(wallet.organization_id, authorize?: false)

      assert setting.mode == :off
    end

    test "a threshold below $1 is rejected and nothing persists", %{conn: conn, wallet: wallet} do
      {:ok, view, _html} = live(conn, ~p"/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "0",
          "amount_dollars" => "10"
        }
      })

      assert has_element?(view, "#flash-error", "at least $1.")

      assert {:ok, setting} =
               Billing.get_auto_recharge_setting(wallet.organization_id, authorize?: false)

      assert setting.mode == :off
    end

    test "a crafted submit missing the fields is rejected", %{conn: conn} do
      # A raw event push, not a form submit — the DOM inputs always
      # merge their values into a submit, so the missing-fields shape
      # is a crafted event's shape (the whole_dollars nil arm).
      {:ok, view, _html} = live(conn, ~p"/billing")

      render_click(view, "save-auto-recharge", %{"auto_recharge" => %{"mode" => "reminder"}})

      assert has_element?(view, "#flash-error", "at least $1.")
    end

    test "a crafted non-map payload is a no-op, never a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing")

      render_click(view, "validate-auto-recharge", %{"auto_recharge" => "x"})
      assert has_element?(view, "[data-testid='auto-recharge-card']")

      render_click(view, "save-auto-recharge", %{"auto_recharge" => "x"})
      assert has_element?(view, "[data-testid='auto-recharge-card']")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")

      # A crafted non-scalar MODE rides to the domain's enum and comes
      # back as a flash error, never a crash.
      render_click(view, "save-auto-recharge", %{
        "auto_recharge" => %{"mode" => %{"deep" => "x"}}
      })

      assert has_element?(view, "#flash-error", "Couldn't save the reminder settings.")
    end

    test "a non-round stored value prefills EMPTY with the exact-value hint", %{
      conn: conn,
      user: user,
      wallet: wallet
    } do
      # 549¢ is a legal row the whole-dollar unit cannot type: the
      # input must stay EMPTY (never a floored "5" that would silently
      # floor on an unedited save), with the hint naming the stored
      # exact value. The mount itself ensures the row.
      {:ok, _pre_view, _html} = live(conn, ~p"/billing")

      {:ok, setting} =
        Billing.get_auto_recharge_setting(wallet.organization_id, authorize?: false)

      assert {:ok, _set} =
               Billing.set_auto_recharge_setting(setting, %{threshold_cents: 549}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "input#auto_recharge_threshold_dollars[value='']")
      assert has_element?(view, "[data-testid='auto-recharge-threshold-hint']", "Stored: $5.49")
      refute has_element?(view, "input#auto_recharge_threshold_dollars[value='5']")
    end

    test "disabling reminders is a mode-only save — a non-round row needs no dollar input", %{
      conn: conn,
      user: user,
      wallet: wallet
    } do
      # 549¢ prefills EMPTY (never-floor), so an off save that demanded
      # whole-dollar figures would force the owner to re-enter stored
      # values just to switch reminders off. Mode-only: stored cents
      # survive untouched.
      {:ok, _view, _html} = live(conn, ~p"/billing")

      {:ok, setting} =
        Billing.get_auto_recharge_setting(wallet.organization_id, authorize?: false)

      assert {:ok, _set} =
               Billing.set_auto_recharge_setting(
                 setting,
                 %{mode: :reminder, threshold_cents: 549, amount_cents: 549},
                 actor: user
               )

      {:ok, view, _html} = live(conn, ~p"/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{"auto_recharge" => %{"mode" => "off"}})

      assert has_element?(view, "#flash-info", "Reminder settings saved.")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Reminders are off")

      assert {:ok, persisted} =
               Billing.get_auto_recharge_setting(wallet.organization_id, authorize?: false)

      assert persisted.mode == :off
      assert persisted.threshold_cents == 549
      assert persisted.amount_cents == 549
    end
  end

  # ── The staged charge card (S5, personal surface) ──
  #
  # The org suite owns the exhaustive matrix; this file mirrors the
  # cases the personal integration must answer (the L3 discipline: the
  # surfaces wire identically, each proving its own wiring). The gate
  # rides a stub, never app-env mutation; provider legs ride Mimic
  # canaries. NO live Polar call exists in this lane.

  describe "the charge card, gate OFF (the parity pin)" do
    setup do
      stub(Billing, :auto_recharge_charge_mode?, fn -> false end)
      :ok
    end

    test "the card renders the launch testids and NOTHING more", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing")

      for testid <-
            ~w(auto-recharge-card auto-recharge-state auto-recharge-form auto-recharge-mode auto-recharge-threshold auto-recharge-amount-input auto-recharge-save) do
        assert has_element?(view, "[data-testid='#{testid}']")
      end

      for testid <-
            ~w(auto-recharge-method auto-recharge-method-status add-payment-method auto-recharge-method-hint auto-recharge-activity auto-recharge-charge-fields auto-recharge-cap auto-recharge-strikes auto-recharge-country auto-recharge-customer-type auto-recharge-vat auto-recharge-arm-confirm auto-recharge-disabled) do
        refute has_element?(view, "[data-testid='#{testid}']")
      end

      refute has_element?(view, "#auto-recharge-form option[value='auto']")
    end

    test "the add-method event is refused — no provider call, no crash", %{conn: conn} do
      parent = self()

      stub(Polar, :create_billing_session, fn _request, _opts ->
        send(parent, :provider_called_with_gate_off)
        flunk("no provider call with the gate off")
      end)

      {:ok, view, _html} = live(conn, ~p"/billing")

      render_click(view, "add-payment-method", %{})

      assert has_element?(view, "[data-testid='auto-recharge-card']")
      refute_received(:provider_called_with_gate_off)
    end
  end

  describe "the charge card, gate ON" do
    setup %{conn: conn, user: user, wallet: wallet} do
      stub(Billing, :auto_recharge_charge_mode?, fn -> true end)
      org_id = wallet.organization_id

      # The provisioning seam (the pages' own posture): the row may not
      # exist yet — nothing has mounted.
      org = Ash.get!(FluxVale.Accounts.Organization, org_id, authorize?: false)
      {:ok, setting} = Billing.ensure_auto_recharge_setting(org)

      %{
        org_id: org_id,
        setting: setting,
        owner_email: AccountsFixtures.primary_address!(user)
      }
    end

    defp attach_method!(setting, customer_id \\ "cust_test") do
      setting
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: customer_id
      })
      |> Ash.update!(authorize?: false)
    end

    test "the method block renders and the button is disabled without evidence", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "[data-testid='auto-recharge-method']")
      assert has_element?(view, "[data-testid='auto-recharge-method-status']", "None saved yet")
      assert has_element?(view, "button[data-testid='add-payment-method'][disabled]")
      assert has_element?(view, "[data-testid='auto-recharge-method-hint']")
      assert has_element?(view, "[data-testid='auto-recharge-charge-fields']")
      assert has_element?(view, "[data-testid='auto-recharge-activity-empty']")
    end

    test "the add-method click mints the session, persists the customer ref, redirects", %{
      conn: conn,
      org_id: org_id,
      setting: setting,
      user: user,
      owner_email: owner_email
    } do
      {:ok, setting} =
        Billing.set_auto_recharge_setting(setting, %{billing_country: "US"}, actor: user)

      parent = self()

      stub(Polar, :create_billing_session, fn request, _opts ->
        send(parent, {:session_request, request})
        {:ok, %{customer_id: "cust_personal", portal_url: "https://portal.example/personal"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/billing")

      assert {:error, {:redirect, %{to: "https://portal.example/personal"}}} =
               render_click(view, "add-payment-method", %{})

      assert_received {:session_request, request}
      assert request.email == owner_email
      assert request.organization_id == org_id
      assert request.billing_address == %{country: "US", state: nil}

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org_id, authorize?: false)
      assert persisted.provider_customer_id == "cust_personal"
      assert persisted.payment_method_status == :none
    end

    test "the mount sync attaches on count > 0", %{conn: conn, org_id: org_id, setting: setting} do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 2, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "[data-testid='auto-recharge-method-status']", "Saved")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org_id, authorize?: false)
      assert persisted.payment_method_status == :attached
    end

    test "a sync fault leaves the stored state untouched (the next mount retries)", %{
      conn: conn,
      org_id: org_id,
      setting: setting
    } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:error, :network_error} end)

      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "[data-testid='auto-recharge-method-status']", "Saved")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org_id, authorize?: false)
      assert persisted.payment_method_status == :attached
    end

    test "the charge dials' bounds are rejected and nothing persists", %{
      conn: conn,
      org_id: org_id
    } do
      {:ok, view, _html} = live(conn, ~p"/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "5",
          "amount_dollars" => "25",
          "daily_charge_cap" => "0",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "#flash-error", "Max charges per day must be between 1 and 6.")

      # A crafted save missing the dials entirely hits the same arm —
      # the DOM always carries them on a real submit.
      render_click(view, "save-auto-recharge", %{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "5",
          "amount_dollars" => "25"
        }
      })

      assert has_element?(view, "#flash-error", "Max charges per day")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "5",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "9"
        }
      })

      assert has_element?(view, "#flash-error", "The decline limit must be between 2 and 5.")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org_id, authorize?: false)
      assert persisted.daily_charge_cap == 2
      assert persisted.failure_strikes == 3
      assert persisted.mode == :off
    end

    test "the charge settings save persists dials + evidence", %{
      conn: conn,
      org_id: org_id
    } do
      {:ok, view, _html} = live(conn, ~p"/billing")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "reminder",
          "threshold_dollars" => "5",
          "amount_dollars" => "25",
          "daily_charge_cap" => "3",
          "failure_strikes" => "4",
          "billing_country" => "GB",
          "customer_type" => "business"
        }
      })

      assert has_element?(view, "#flash-info", "Reminder settings saved.")

      assert {:ok, persisted} = Billing.get_auto_recharge_setting(org_id, authorize?: false)
      assert persisted.daily_charge_cap == 3
      assert persisted.failure_strikes == 4
      assert persisted.billing_country == "GB"
      assert persisted.customer_type == :business
    end

    test "arming is its own confirmed action: save opens the step, confirm arms, cancel doesn't",
         %{
           conn: conn,
           org_id: org_id,
           setting: setting
         } do
      attach_method!(setting)
      stub(Polar, :list_payment_methods, fn _id -> {:ok, 1, "pm_default"} end)

      {:ok, view, _html} = live(conn, ~p"/billing")

      # The option mirrors the AutoArmGate's admission.
      assert has_element?(view, "#auto-recharge-form option[value='auto']")

      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "5",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      assert has_element?(view, "[data-testid='auto-recharge-arm-confirm']")
      assert has_element?(view, "[data-testid='auto-recharge-arm-math']")

      # Cancel — no write.
      view
      |> element("#arm-auto-cancel")
      |> render_click()

      refute has_element?(view, "[data-testid='auto-recharge-arm-confirm']")

      assert {:ok, not_armed} = Billing.get_auto_recharge_setting(org_id, authorize?: false)
      assert not_armed.mode == :off

      # Confirm — the write.
      view
      |> element("#auto-recharge-form")
      |> render_submit(%{
        "auto_recharge" => %{
          "mode" => "auto",
          "threshold_dollars" => "5",
          "amount_dollars" => "25",
          "daily_charge_cap" => "2",
          "failure_strikes" => "3"
        }
      })

      view
      |> element("#arm-auto-confirm")
      |> render_click()

      assert has_element?(view, "#flash-info", "Auto charging armed.")
      assert has_element?(view, "[data-testid='auto-recharge-state']", "Auto charging armed")

      assert {:ok, armed} = Billing.get_auto_recharge_setting(org_id, authorize?: false)
      assert armed.mode == :auto
    end

    test "recent activity renders the :auto rows; :manual never appears", %{
      conn: conn,
      org_id: org_id
    } do
      {:ok, auto} =
        Topup.create(
          %{organization_id: org_id, amount_cents: 2_500, origin: :auto},
          authorize?: false
        )

      auto
      |> Ash.Changeset.for_update(:mark_completed, %{})
      |> Ash.update!(authorize?: false)

      {:ok, _manual} =
        Topup.create(%{organization_id: org_id, amount_cents: 1_500}, authorize?: false)

      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "$25")
      assert has_element?(view, "[data-testid='auto-recharge-activity-row']", "Completed")
      refute has_element?(view, "[data-testid='auto-recharge-activity-row']", "$15")
    end
  end
end
