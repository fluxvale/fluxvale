defmodule FluxValeWeb.BillingLive.TopupTest do
  @moduledoc false

  # The top-up wizard (#137): the four steps, the live VAT line resolved
  # from the billing country's rate (#138 — consumer rate, B2B reverse
  # charge), the new-balance preview, the never-expires/non-refundable
  # notice, the checkout handoff, and the Confirmation step's
  # reconciliation. Gateway calls are Mimic-stubbed (Req); the webhook
  # path has its own controller suite.

  # async: false — the "pay" tests stub the global :hitpay app-env block.
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.Pricing.TaxRate
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

  @effective_from ~U[2021-01-01 00:00:00.000000Z]

  setup %{conn: conn} do
    {user, conn} = SessionHelpers.user_with_session(conn)
    org = AccountsFixtures.personal_org!(user)
    {:ok, wallet} = Billing.ensure_wallet(org)

    # Pin the start at exactly zero (the welcome grant varies) so the
    # new-balance preview asserts exact arithmetic.
    {:ok, balance} = Billing.balance(wallet, authorize?: false)

    if balance > 0 do
      {:ok, _drain} = Billing.debit_wallet(wallet, balance * 10_000)
    end

    %{user: user, conn: conn, org: org, wallet: wallet}
  end

  describe "step 1 — billing details" do
    test "renders the form with the actor's email prefilled", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      assert has_element?(view, "#topup-details-form")
      assert has_element?(view, "#topup-details-form input[name='details[email]']")
      assert has_element?(view, "[data-testid='topup-step-details']")
    end

    test "typing updates the details without advancing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      view
      |> form("#topup-details-form",
        details: %{name: "Jane Doe", email: "jane@example.com", country: "DE"}
      )
      |> render_change()

      assert has_element?(view, "#topup-details-form")
    end

    test "back on the first step is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      render_click(view, "back")

      assert has_element?(view, "#topup-details-form")
    end

    test "invalid details keep the step and explain", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      view
      |> form("#topup-details-form",
        details: %{name: "", email: "not-an-email", country: "deutschland"}
      )
      |> render_submit()

      assert has_element?(view, "#topup-details-form")
      assert render(view) =~ "2-letter country code"
    end

    test "valid details advance to the amount step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      view
      |> form("#topup-details-form",
        details: %{name: "Jane Doe", email: "jane@example.com", country: "de"}
      )
      |> render_submit()

      assert has_element?(view, "#topup-amount-form")
    end

    test "the US state field appears only for US buyers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      refute has_element?(view, "input[name='details[state]']")

      view
      |> form("#topup-details-form",
        details: %{name: "Jane Doe", email: "jane@example.com", country: "US"}
      )
      |> render_change()

      assert has_element?(view, "input[name='details[state]']")

      # Back to a non-US country and the field folds away again.
      view
      |> form("#topup-details-form",
        details: %{name: "Jane Doe", email: "jane@example.com", country: "DE"}
      )
      |> render_change()

      refute has_element?(view, "input[name='details[state]']")
    end

    test "a US buyer must name a state to continue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      details = %{name: "Jane Doe", email: "jane@example.com", country: "US", state: ""}

      # Shape the DOM first (the state field exists only for the US).
      view
      |> form("#topup-details-form", details: Map.delete(details, :state))
      |> render_change()

      view
      |> form("#topup-details-form", details: details)
      |> render_submit()

      assert has_element?(view, "#topup-details-form")
      assert render(view) =~ "2-letter US state"
    end

    test "the VAT number field appears only for business buyers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      refute has_element?(view, "input[name='details[vat_number]']")

      view
      |> form("#topup-details-form",
        details: %{
          name: "Jane Doe",
          email: "jane@example.com",
          country: "DE",
          customer_type: "business"
        }
      )
      |> render_change()

      assert has_element?(view, "input[name='details[vat_number]']")
    end
  end

  describe "step 2 — amount" do
    # The conditional fields shape the DOM (state for the US, VAT for
    # business), so the fill runs in two phases: a change to re-render,
    # then the submit with whatever the shaped DOM renders.
    defp to_amount(conn, overrides \\ %{}) do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      details =
        Map.merge(
          %{
            name: "Jane Doe",
            email: "jane@example.com",
            country: "DE",
            state: "CA",
            customer_type: "consumer",
            vat_number: "DE123456789"
          },
          Map.new(overrides)
        )

      view
      |> form("#topup-details-form",
        details: Map.take(details, [:name, :email, :country, :customer_type])
      )
      |> render_change()

      view
      |> form("#topup-details-form", details: dom_details(details))
      |> render_submit()

      view
    end

    defp dom_details(details) do
      details
      |> drop_unless(details.country == "US", :state)
      |> drop_unless(details.customer_type == "business", :vat_number)
    end

    defp drop_unless(map, true, _key), do: map
    defp drop_unless(map, false, key), do: Map.delete(map, key)

    test "an unpriced country shows a 0% VAT line and the unit total", %{conn: conn} do
      view = to_amount(conn, country: "AU")

      view
      |> form("#topup-amount-form", amount: %{dollars: "10"})
      |> render_change()

      taxes = render(element(view, "[data-testid='topup-taxes']"))
      assert taxes =~ "VAT (0%)"
      assert taxes =~ "$0.00"

      assert render(element(view, "[data-testid='topup-total']")) =~ "$10.00"
      assert render(element(view, "[data-testid='topup-new-balance']")) =~ "$10.00"
    end

    test "a DE consumer sees the country rate on the VAT line", %{conn: conn} do
      # 19% — the German standard rate the launch table ships.
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      view = to_amount(conn)

      view
      |> form("#topup-amount-form", amount: %{dollars: "10"})
      |> render_change()

      taxes = render(element(view, "[data-testid='topup-taxes']"))
      assert taxes =~ "VAT (19%)"
      assert taxes =~ "$1.90"

      assert render(element(view, "[data-testid='topup-total']")) =~ "$11.90"
      # The note is gone where a real rate shows.
      refute render(view) =~ "Final taxes are calculated at checkout."
    end

    test "a B2B buyer with a valid VAT number reverse-charges at 0%", %{conn: conn} do
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      view =
        to_amount(conn, %{
          customer_type: "business",
          vat_number: "de123456789"
        })

      view
      |> form("#topup-amount-form", amount: %{dollars: "10"})
      |> render_change()

      taxes = render(element(view, "[data-testid='topup-taxes']"))
      assert taxes =~ "VAT (reverse charge, 0%)"
      assert taxes =~ "$0.00"
      assert render(element(view, "[data-testid='topup-total']")) =~ "$10.00"
    end

    test "the never-expires/non-refundable notice is stated", %{conn: conn} do
      view = to_amount(conn)

      notice = render(element(view, "[data-testid='topup-notice']"))
      # No trailing period — the sentence now ends in the linked policy
      # tail (asserted on its own below).
      assert notice =~ "Credits can be used for any app, never expire, and are non-refundable"
    end

    test "the notice links the refund policy — before any payment", %{conn: conn} do
      view = to_amount(conn)

      assert has_element?(
               view,
               "a[data-testid='topup-refund-policy'][href='/policies/refund']",
               "refund policy"
             )
    end

    test "a fractional or empty amount keeps the step", %{conn: conn} do
      view = to_amount(conn)

      form2 = form(view, "#topup-amount-form", amount: %{dollars: "2.5"})
      render_submit(form2)
      assert has_element?(view, "#topup-amount-form")
      assert render(view) =~ "whole-dollar amount"

      empty = form(view, "#topup-amount-form", amount: %{dollars: ""})
      render_submit(empty)
      assert has_element?(view, "#topup-amount-form")
    end

    test "a valid amount advances to the payment step", %{conn: conn} do
      view = to_amount(conn)

      submit = form(view, "#topup-amount-form", amount: %{dollars: "5"})
      render_submit(submit)

      assert has_element?(view, "#topup-pay")
    end

    test "back returns from payment to the amount step", %{conn: conn} do
      view = to_payment(conn)

      render_click(view, "back")

      assert has_element?(view, "#topup-amount-form")
    end
  end

  describe "step 3 — payment" do
    defp to_payment(conn, overrides \\ %{}) do
      view = to_amount(conn, overrides)

      submit = form(view, "#topup-amount-form", amount: %{dollars: "5"})
      render_submit(submit)

      view
    end

    setup %{conn: conn} = context do
      original = Application.get_env(:flux_vale, :hitpay)

      Application.put_env(:flux_vale, :hitpay,
        api_key: "sbx_key",
        webhook_salt: "salt",
        base_url: "https://api.example"
      )

      on_exit(fn -> Application.put_env(:flux_vale, :hitpay, original) end)

      Map.put(context, :conn, conn)
    end

    test "the payment step links the refund policy where the payment decision is made", %{
      conn: conn
    } do
      view = to_payment(conn)

      # #140: the buyer can read the full policy BEFORE the pay click —
      # the notice sentence links the published page.
      assert has_element?(
               view,
               "a[data-testid='topup-refund-policy'][href='/policies/refund']",
               "refund policy"
             )
    end

    test "pay creates the top-up and redirects to the hosted checkout", %{
      conn: conn,
      org: org
    } do
      view = to_payment(conn)

      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
      end)

      _result = render_click(view, "pay")

      # The event's contract is the external handoff to the hosted
      # checkout; the redirect is recorded by the time render returns.
      assert_redirect(view, "https://checkout/pr_1")

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert [%Topup{status: :pending, payment_request_id: "pr_1", amount_cents: 500}] = topups
    end

    test "a hostile details swap from the payment step reprices the charge", %{
      conn: conn,
      org: org
    } do
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      TaxRate.create!(
        %{country: "FR", rate_bp: 2900, effective_from: @effective_from},
        authorize?: false
      )

      # DE details carried the wizard to the payment step (rate 19%
      # resolved along the way). A hostile client can still push a
      # validate-details event there — the details swap to FR and the
      # rate assign follows the swapped details (#260: the assign is
      # the charge's single source).
      view = to_payment(conn)

      render_change(view, "validate-details", %{
        "details" => %{
          "name" => "Jane Doe",
          "email" => "jane@example.com",
          "country" => "FR",
          "customer_type" => "consumer"
        }
      })

      parent = self()

      expect(Req, :post, fn _req, opts ->
        send(parent, {:form, opts[:form]})
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://x/pr_1"}}}
      end)

      _result = render_click(view, "pay")

      # The charge prices the swapped FR details — a stale DE assign
      # (19%, 95¢ on $5) must not leak into the checkout.
      assert_receive {:form, form}
      assert {"amount", "6.45"} in form

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert [
               %Topup{
                 billing_country: "FR",
                 tax_rate_bp: 2900,
                 tax_cents: 145,
                 amount_cents: 500
               }
             ] = topups
    end

    # #260: display and charge read ONE source — the rate assign. A
    # table change mid-session fails the checkout closed (no charge,
    # no row), re-displays the current figures, and the retried pay
    # charges exactly the re-displayed total.
    test "a mid-session rate change fails closed, re-displays, then charges the displayed total",
         %{conn: conn, org: org} do
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      view = to_payment(conn)

      assert render(element(view, "#topup-pay")) =~ "$5.95"

      # The table moves under the session: 21%, effective now.
      TaxRate.create!(
        %{country: "DE", rate_bp: 2100, effective_from: DateTime.utc_now()},
        authorize?: false
      )

      canary = self()

      stub(Req, :post, fn _req, _opts ->
        send(canary, :unexpected_gateway_call)

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "pr_leak", "url" => "https://x/pr_leak"}}}
      end)

      html = render_click(view, "pay")

      refute_received :unexpected_gateway_call
      assert html =~ "The VAT rate changed"
      assert render(element(view, "[data-testid='topup-taxes']")) =~ "VAT (21%)"
      assert render(element(view, "#topup-pay")) =~ "$6.05"

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert topups == []

      parent = self()

      expect(Req, :post, fn _req, opts ->
        send(parent, {:form, opts[:form]})
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://x/pr_1"}}}
      end)

      _result = render_click(view, "pay")

      assert_redirect(view, "https://x/pr_1")

      assert_receive {:form, form}
      assert {"amount", "6.05"} in form
    end

    test "an invalid detail edit never leaks a rate into a charge", %{
      conn: conn,
      org: org
    } do
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      view = to_payment(conn)

      # A hostile validate-details on the payment step with broken
      # details: the rate assign resets to the 0% placeholder and the
      # invalid details fail the payable guard — no checkout, no row.
      render_change(view, "validate-details", %{
        "details" => %{"name" => "", "email" => "jane@example.com", "country" => "DE"}
      })

      html = render_click(view, "pay")

      assert html =~ "Review and pay"

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert topups == []
    end

    test "a DE consumer checkout charges the gross and records the rate", %{
      conn: conn,
      org: org
    } do
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      view = to_payment(conn)

      # The stub runs in the LiveView process — send the gateway form
      # to this test process explicitly.
      parent = self()

      expect(Req, :post, fn _req, opts ->
        send(parent, {:form, opts[:form]})
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://x/pr_1"}}}
      end)

      _result = render_click(view, "pay")

      assert_receive {:form, form}
      assert {"amount", "5.95"} in form

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert [
               %Topup{
                 status: :pending,
                 amount_cents: 500,
                 tax_rate_bp: 1900,
                 tax_cents: 95,
                 customer_type: :consumer,
                 reverse_charge?: false
               }
             ] = topups
    end

    test "a B2B checkout reverse-charges and records the proofs on the row", %{
      conn: conn,
      org: org
    } do
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      view =
        to_payment(conn, %{customer_type: "business", vat_number: "DE123456789"})

      # The billed-to line carries the VAT proof for business buyers.
      assert render(element(view, "[data-testid='topup-billed-to']")) =~
               "VAT DE123456789"

      parent = self()

      expect(Req, :post, fn _req, opts ->
        send(parent, {:form, opts[:form]})
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://x/pr_1"}}}
      end)

      _result = render_click(view, "pay")

      # 0% — the customer self-accounts.
      assert_receive {:form, form}
      assert {"amount", "5.00"} in form

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert [
               %Topup{
                 amount_cents: 500,
                 tax_rate_bp: 0,
                 tax_cents: 0,
                 customer_type: :business,
                 vat_number: "DE123456789",
                 reverse_charge?: true
               }
             ] = topups
    end

    test "the IP country rides the session into the row's location evidence", %{
      conn: conn,
      org: org
    } do
      # The edge geo header lands in the session (CaptureIpCountry) on
      # the way through the :browser pipeline — the header, not a
      # hand-set session value, is the signal's path.
      conn = Plug.Conn.put_req_header(conn, "cf-ipcountry", "de")

      view = to_payment(conn)

      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
      end)

      _result = render_click(view, "pay")

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert [%Topup{billing_country: "DE", ip_country: "DE", ip_matches_billing?: true}] =
               topups
    end

    test "a US checkout captures the billing state", %{conn: conn, org: org} do
      view = to_payment(conn, %{country: "US", state: "ca"})

      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
      end)

      _result = render_click(view, "pay")

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert [%Topup{billing_country: "US", billing_state: "CA"}] = topups
    end

    test "the payment step shows the correction affordance and the gross", %{conn: conn} do
      TaxRate.create!(
        %{country: "DE", rate_bp: 1900, effective_from: @effective_from},
        authorize?: false
      )

      view = to_payment(conn)

      assert render(element(view, "[data-testid='topup-correction']")) =~
               "Let us know if this is not correct"

      assert render(element(view, "#topup-pay")) =~ "$5.95"

      # A consumer's billed-to line names the buyer and country — no
      # dangling "VAT" (an empty vat_number is not a proof).
      billed_to = render(element(view, "[data-testid='topup-billed-to']"))
      assert billed_to =~ "Jane Doe · jane@example.com · DE"
      refute billed_to =~ "VAT"
    end

    test "unconfigured payments answer a plain error, nothing charged", %{conn: conn} do
      view = to_payment(conn)

      Application.put_env(:flux_vale, :hitpay, base_url: "https://api.example")

      html = render_click(view, "pay")

      assert html =~ "Payments aren&#39;t configured on this environment yet"
      assert has_element?(view, "#topup-pay")
    end

    test "a gateway failure keeps the step with a retry hint", %{conn: conn} do
      view = to_payment(conn)

      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 502, body: %{}}}
      end)

      html = render_click(view, "pay")

      assert html =~ "The checkout couldn&#39;t be opened"
      assert has_element?(view, "#topup-pay")
    end

    test "pay from an earlier step is ignored — no crash, no checkout", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      # A hostile client pushing "pay" before any step data exists:
      # nil amount must not ArithmeticError the LiveView, and no
      # top-up row may appear.
      render_click(view, "pay")

      assert has_element?(view, "#topup-details-form")

      topups =
        Topup
        |> Ash.Query.filter(organization_id == ^org.id)
        |> Ash.read!(authorize?: false)

      assert topups == []
    end
  end

  describe "step 4 — confirmation (the gateway return)" do
    setup %{wallet: wallet} = context do
      original = Application.get_env(:flux_vale, :hitpay)

      Application.put_env(:flux_vale, :hitpay,
        api_key: "sbx_key",
        webhook_salt: "salt",
        base_url: "https://api.example"
      )

      on_exit(fn -> Application.put_env(:flux_vale, :hitpay, original) end)

      {:ok, topup} =
        Topup.create(
          %{
            organization_id: context.org.id,
            amount_cents: 500,
            buyer_email: "jane@example.com",
            billing_country: "DE"
          },
          authorize?: false
        )

      {:ok, attached} =
        Topup.attach_checkout(topup, %{payment_request_id: "pr_1"}, authorize?: false)

      Map.merge(context, %{wallet: wallet, topup: attached})
    end

    test "a webhook-completed row shows payment received", %{conn: conn} do
      {:ok, _completed} =
        Billing.complete_topup(%{
          payment_request_id: "pr_1",
          payment_id: "pay_1",
          amount_cents: 500,
          idempotency_key: "hitpay:pay_1"
        })

      {:ok, view, _html} = live(conn, ~p"/billing/topup/return?reference=pr_1&status=completed")

      assert has_element?(view, "[data-testid='topup-confirmation-completed']")
      assert render(view) =~ "$5.00"
    end

    test "a pending row reconciles through the gateway and lands completed", %{conn: conn} do
      # stub, not expect — reconciliation runs in the LiveView process
      # at mount, outside this process's Mimic expectations.
      stub(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "id" => "pr_1",
             "status" => "completed",
             "amount" => "5.00",
             "payments" => [%{"id" => "pay_1", "status" => "succeeded", "amount" => "5.00"}]
           }
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/billing/topup/return?reference=pr_1&status=completed")

      assert has_element?(view, "[data-testid='topup-confirmation-completed']")
    end

    test "a still-pending gateway state shows the finalizing message", %{conn: conn} do
      stub(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "pr_1", "status" => "pending", "amount" => "5.00"}
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/billing/topup/return?reference=pr_1&status=pending")

      assert has_element?(view, "[data-testid='topup-confirmation-pending']")
    end

    test "a gateway error keeps the finalizing message (webhook owns the outcome)", %{conn: conn} do
      stub(Req, :get, fn _req, _opts -> {:error, %Req.TransportError{reason: :timeout}} end)

      {:ok, view, _html} = live(conn, ~p"/billing/topup/return?reference=pr_1&status=completed")

      assert has_element?(view, "[data-testid='topup-confirmation-pending']")
    end

    test "a webhook completing the row mid-reconcile still lands completed", %{
      conn: conn,
      wallet: wallet
    } do
      # The webhook races the return: the row completes while
      # reconciliation's gateway fetch is in flight — the idempotent
      # credit makes both orders land on completed.
      stub(Req, :get, fn _req, _opts ->
        {:ok, _topup} =
          Billing.complete_topup(%{
            payment_request_id: "pr_1",
            payment_id: "pay_1",
            amount_cents: 500,
            idempotency_key: "hitpay:pay_1"
          })

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "id" => "pr_1",
             "status" => "completed",
             "amount" => "5.00",
             "payments" => [%{"id" => "pay_1", "status" => "succeeded", "amount" => "5.00"}]
           }
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/billing/topup/return?reference=pr_1&status=completed")

      assert has_element?(view, "[data-testid='topup-confirmation-completed']")
      assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    end

    test "a failed gateway outcome shows the failed card", %{conn: conn, wallet: wallet} do
      stub(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "pr_1", "status" => "failed", "amount" => "5.00"}
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/billing/topup/return?reference=pr_1&status=failed")

      assert has_element?(view, "[data-testid='topup-confirmation-failed']")
      assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
    end

    test "a completion racing a failed gateway state still shows completed", %{conn: conn} do
      # The webhook completes the row while reconciliation's fetch is
      # in flight and the gateway still reports failed — the guarded
      # write refuses the flip and the confirmation re-reads the truth.
      stub(Req, :get, fn _req, _opts ->
        {:ok, _topup} =
          Billing.complete_topup(%{
            payment_request_id: "pr_1",
            payment_id: "pay_1",
            amount_cents: 500,
            idempotency_key: "hitpay:pay_1"
          })

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "pr_1", "status" => "failed", "amount" => "5.00"}
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/billing/topup/return?reference=pr_1&status=failed")

      assert has_element?(view, "[data-testid='topup-confirmation-completed']")
    end

    test "an unknown reference shows the not-found card", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/billing/topup/return?reference=pr_other&status=completed")

      assert render(view) =~ "We couldn&#39;t find that top-up"
    end

    test "a stranger's reference shows the not-found card (policy, not silence)", %{
      conn: conn
    } do
      stranger = AccountsFixtures.user!()
      stranger_org = AccountsFixtures.personal_org!(stranger)
      {:ok, _stranger_wallet} = Billing.ensure_wallet(stranger_org)

      {:ok, topup} =
        Topup.create(%{organization_id: stranger_org.id, amount_cents: 500}, authorize?: false)

      {:ok, _attached} =
        Topup.attach_checkout(topup, %{payment_request_id: "pr_stranger"}, authorize?: false)

      {:ok, view, _html} =
        live(conn, ~p"/billing/topup/return?reference=pr_stranger&status=completed")

      assert render(view) =~ "We couldn&#39;t find that top-up"
    end
  end

  describe "the billing page" do
    test "links to the wizard with the credit terms", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/billing")

      assert has_element?(view, "#add-credits")
      assert render(element(view, "#add-credits")) =~ "/billing/topup"
      assert render(view) =~ "never expire, and are non-refundable"
    end
  end

  test "an orgless user is redirected to the apps surface", %{conn: conn} do
    # Ash.seed! — the only way to produce an org-less user (the create
    # action's JIT change always provisions one).
    orgless =
      Ash.Seed.seed!(FluxVale.Identity.User, %{
        email: "orgless-#{System.unique_integer()}@fluxvale.test"
      })

    conn = SessionHelpers.sign_in(conn, orgless)

    case live(conn, ~p"/billing/topup") do
      {:ok, view, _html} ->
        assert_redirect(view, ~p"/apps")

      {:error, {:live_redirect, %{to: to}}} ->
        assert to == ~p"/apps"
    end
  end
end
