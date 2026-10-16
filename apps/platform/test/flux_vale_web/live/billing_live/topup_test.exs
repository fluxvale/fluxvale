defmodule FluxValeWeb.BillingLive.TopupTest do
  @moduledoc false

  # The top-up wizard (#137): the four steps, the 0% VAT line with its
  # "calculated at checkout" note, the new-balance preview, the
  # never-expires/non-refundable notice, the checkout handoff, and the
  # Confirmation step's reconciliation. Gateway calls are Mimic-stubbed
  # (Req); the webhook path has its own controller suite.

  # async: false — the "pay" tests stub the global :hitpay app-env block.
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.SessionHelpers

  require Ash.Query

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
  end

  describe "step 2 — amount" do
    defp to_amount(conn) do
      {:ok, view, _html} = live(conn, ~p"/billing/topup")

      view
      |> form("#topup-details-form",
        details: %{name: "Jane Doe", email: "jane@example.com", country: "DE"}
      )
      |> render_submit()

      view
    end

    test "a whole-dollar amount shows the unit line, the 0% VAT line, the total, and the preview",
         %{conn: conn} do
      view = to_amount(conn)

      view
      |> form("#topup-amount-form", amount: %{dollars: "10"})
      |> render_change()

      summary = element(view, "[data-testid='topup-summary']")
      html = render(summary)
      assert html =~ "10 × $1.00 credit"
      assert html =~ "$10.00"

      taxes = render(element(view, "[data-testid='topup-taxes']"))
      assert taxes =~ "Taxes (0%)"
      assert taxes =~ "$0.00"
      assert render(element(view, "[data-testid='topup-total']")) =~ "$10.00"
      assert render(element(view, "[data-testid='topup-new-balance']")) =~ "$10.00"

      # The tax-layer placeholder note rides the same block.
      assert html =~ "Final taxes are calculated at checkout."
    end

    test "the never-expires/non-refundable notice is stated", %{conn: conn} do
      view = to_amount(conn)

      notice = render(element(view, "[data-testid='topup-notice']"))
      assert notice =~ "Credits can be used for any app, never expire, and are non-refundable."
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
    defp to_payment(conn) do
      view = to_amount(conn)

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
