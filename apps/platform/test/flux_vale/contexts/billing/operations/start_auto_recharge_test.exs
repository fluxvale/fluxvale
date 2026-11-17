defmodule FluxVale.Billing.Operations.StartAutoRechargeTest do
  @moduledoc """
  StartAutoRecharge contract (#829 S3): the staged charge attempt —
  `:auto` row → draft order → attached order id → one finalize. The
  starter never credits; declines and strikes commit atomically;
  unknown outcomes leave a reconcilable pending row and are never
  re-driven.
  """

  # async: false — stubs the global :polar app-env block and the
  # payments-provider default (Req is Mimic-stubbed for the gateway
  # legs), and flips the global charge-mode gate.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Tax
  alias FluxVale.Billing.Topup
  alias FluxVale.Pricing.TaxRate
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  setup do
    original_polar = Application.get_env(:flux_vale, :polar)

    Application.put_env(:flux_vale, :polar,
      access_token: "tok",
      webhook_secret: "secret",
      server: "sandbox",
      product_id: "prod_1"
    )

    # The adapter's default IS Polar (#377 flip) — pinned here so a
    # sibling suite's provider stub can never leak into this lane.
    original_provider = Application.get_env(:flux_vale, :payments_provider)
    Application.put_env(:flux_vale, :payments_provider, FluxVale.Billing.Providers.Polar)

    # The staged lane's gate: on for every charge test, captured for
    # the gate-off refusal (the test-ownership rule).
    original_gate = Application.get_env(:flux_vale, :auto_recharge)
    Application.put_env(:flux_vale, :auto_recharge, charge_mode: true)

    # The rate table the quote resolves against (#260): DE at the
    # launch rate; the reverse-charge and unpriced cases key off it.
    TaxRate.create!(
      %{country: "DE", rate_bp: 1900, effective_from: ~U[2021-01-01 00:00:00Z]},
      authorize?: false
    )

    on_exit(fn ->
      Application.put_env(:flux_vale, :polar, original_polar)
      Application.put_env(:flux_vale, :payments_provider, original_provider)
      Application.put_env(:flux_vale, :auto_recharge, original_gate)
    end)

    :ok
  end

  # {org, setting} armed exactly as the S2 actions produce them: the
  # owner-role write carries the buyer evidence; the system write
  # records the saved method (provider_customer_id).
  defp charged_setting!(evidence \\ %{billing_country: "DE"}) do
    {org, owner} = BillingFixtures.grant_free_org!()

    {:ok, bare} = AutoRechargeSetting.create(%{organization_id: org.id}, authorize?: false)

    {:ok, with_evidence} = Billing.set_auto_recharge_setting(bare, evidence, actor: owner)

    {:ok, setting} =
      with_evidence
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: "cus_1"
      })
      |> Ash.update(authorize?: false)

    {org, setting}
  end

  # 2500¢ net at DE's 1900bp → exactly 475¢ VAT (19% of $25.00) → the
  # 2975¢ gross the drafts echo (the stubbed mapping obeys the gross
  # guard).
  @gross 2_975
  @order_id "ord_1"

  # The draft leg and the finalize leg dispatch on the URL; any other
  # call flunks (the adapter's own base URL is fixed, so a stray call
  # is a bug, not environment noise).
  defp stub_draft do
    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/"
      send(self(), {:draft_body, opts[:json]})

      {:ok, %Req.Response{status: 200, body: %{"id" => @order_id, "subtotal_amount" => @gross}}}
    end)
  end

  defp stub_finalize(outcome) do
    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/#{@order_id}/finalize"
      outcome.()
    end)
  end

  defp paid_finalize do
    fn ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => @order_id, "status" => "paid", "subtotal_amount" => @gross}
       }}
    end
  end

  defp declined_finalize do
    fn ->
      {:ok, %Req.Response{status: 402, body: %{"detail" => "no payment method"}}}
    end
  end

  # The stubbed mapping obeys the gross guard: the draft/finalize
  # responses echo subtotal_amount == the gross we sent (contract
  # point 1 — if Polar ever maps `amount` differently, the MAPPING
  # adjusts, never CompleteTopup's guard).
  test "the happy path: pending row, draft attached, finalize completed, strikes reset" do
    {org, setting} = charged_setting!()
    stub_draft()
    stub_finalize(paid_finalize())

    assert {:ok, :completed, topup} = Billing.start_auto_recharge(org, setting)

    # The attempt IS a top-up (decision A): the `:auto` origin, the net
    # from the setting, the FRESH table rate (#260) — and the starter
    # never credits (the webhook posts it).
    assert topup.status == :pending
    assert topup.origin == :auto
    assert topup.payment_request_id == @order_id
    assert topup.amount_cents == 2_500
    assert topup.tax_rate_bp == 1900
    assert topup.tax_cents == 475
    assert is_nil(topup.buyer_email)
    assert topup.billing_country == "DE"

    # The draft charged the gross with the row as the reference and
    # the setting's stored customer (the sweep cannot repoint it).
    assert_receive {:draft_body, body}

    assert body == %{
             "customer_id" => "cus_1",
             "product_id" => "prod_1",
             "amount" => @gross,
             "metadata" => %{"topup_id" => topup.id}
           }

    # A completed charge resets the strikes and stamps the attempt
    # (the caller contract — the action stores AS GIVEN).
    {:ok, reloaded} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert reloaded.consecutive_failures == 0
    assert %DateTime{} = reloaded.last_attempt_at
  end

  test "a decline marks the row failed and counts the strike atomically" do
    {org, setting} = charged_setting!()
    stub_draft()
    stub_finalize(declined_finalize())

    assert {:ok, :failed, failed, "http_402: no payment method"} =
             Billing.start_auto_recharge(org, setting)

    assert failed.status == :failed
    assert failed.payment_request_id == @order_id

    {:ok, reloaded} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert reloaded.consecutive_failures == 1
    assert %DateTime{} = reloaded.last_attempt_at
  end

  # The crash-between-writes guard: the first write runs for real,
  # then the raise simulates the crash before the second — the
  # transaction must roll BOTH back (an uncounted failure must not be
  # possible, the plan pins it).
  test "a crash between the decline writes persists neither" do
    {org, setting} = charged_setting!()
    stub_draft()
    stub_finalize(declined_finalize())

    expect(Topup, :mark_failed, fn topup, params, opts ->
      assert {:ok, _really_failed, _notifications} =
               Mimic.call_original(Topup, :mark_failed, [topup, params, opts])

      raise "simulated crash between the writes"
    end)

    assert_raise(RuntimeError, fn -> Billing.start_auto_recharge(org, setting) end)

    # Neither write persisted: the row (inserted in its own earlier
    # transaction, per the plan's step order) was never marked failed,
    # and the strike counter never moved.
    assert [row] =
             Topup
             |> Ash.Query.filter(organization_id == ^org.id)
             |> Ash.read!(authorize?: false)

    assert row.status == :pending
    assert row.payment_request_id == @order_id

    {:ok, reloaded} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert reloaded.consecutive_failures == 0
    assert is_nil(reloaded.last_attempt_at)
  end

  # A transport error is an UNKNOWN outcome: the row stays pending
  # WITH its order id (reconciliation keys on it), only the attempt
  # marker moves, and the finalize is never re-driven inside the
  # operation (the counted expects admit exactly two calls: draft,
  # finalize).
  test "an unknown finalize outcome leaves the pending row with its order id" do
    {org, setting} = charged_setting!()
    stub_draft()

    stub_finalize(fn -> {:error, %Req.TransportError{reason: :econnrefused}} end)

    assert {:error, :unknown, topup} = Billing.start_auto_recharge(org, setting)

    assert topup.status == :pending
    assert topup.payment_request_id == @order_id

    {:ok, reloaded} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert reloaded.consecutive_failures == 0
    assert %DateTime{} = reloaded.last_attempt_at
  end

  test "a draft-leg failure leaves the row pending WITHOUT an order id and never finalizes" do
    {org, setting} = charged_setting!()

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/"
      {:error, %Req.TransportError{reason: :econnrefused}}
    end)

    # The finalize URL flunks if reached — the draft failure must end
    # the attempt before any charge trigger.
    stub(Req, :post, fn _req, opts ->
      flunk("no finalize after a failed draft leg: #{inspect(opts[:url])}")
    end)

    assert {:error, :draft_failed, topup} = Billing.start_auto_recharge(org, setting)

    assert topup.status == :pending
    assert is_nil(topup.payment_request_id)

    {:ok, reloaded} = AutoRechargeSetting.get_by_organization(org.id, authorize?: false)
    assert is_nil(reloaded.last_attempt_at)
  end

  test "an attach failure leaves the row pending WITHOUT the order id and never finalizes" do
    {org, setting} = charged_setting!()
    stub_draft()

    expect(Topup, :attach_checkout, 1, fn _topup, _attrs, _opts ->
      {:error, "simulated DB hiccup"}
    end)

    stub(Req, :post, fn _req, opts ->
      flunk("no finalize when the order id never persisted: #{inspect(opts[:url])}")
    end)

    assert {:error, :attach_failed, topup} = Billing.start_auto_recharge(org, setting)

    assert topup.status == :pending
    assert is_nil(topup.payment_request_id)
  end

  test "the gate-off refusal happens before any row or call" do
    {org, setting} = charged_setting!()
    original_gate = Application.get_env(:flux_vale, :auto_recharge)
    Application.put_env(:flux_vale, :auto_recharge, charge_mode: false)

    on_exit(fn -> Application.put_env(:flux_vale, :auto_recharge, original_gate) end)

    stub(Req, :post, fn _req, _opts -> flunk("no provider call with the gate off") end)

    assert {:error, :charge_mode_off} = Billing.start_auto_recharge(org, setting)

    assert [] =
             Topup
             |> Ash.Query.filter(organization_id == ^org.id)
             |> Ash.read!(authorize?: false)
  end

  describe "tax resolution (fresh from the table, #260)" do
    test "quote/2 flows the table rate and half-up rounding" do
      resolution = Tax.quote(%{billing_country: "DE", billing_state: nil}, 2_500)
      assert resolution == %{rate_bp: 1900, tax_cents: 475, reverse_charge?: false}
    end

    test "quote/2 zeroes the rate under reverse charge" do
      resolution =
        Tax.quote(
          %{billing_country: "DE", customer_type: :business, vat_number: "DE123456789"},
          2_500
        )

      assert resolution == %{rate_bp: 0, tax_cents: 0, reverse_charge?: true}
    end

    test "quote/2 prices an unpriced market and a missing country at zero" do
      # PH has no table row (threshold-gated markets stay out); a nil
      # country is the same stance.
      no_row = Tax.quote(%{billing_country: "PH"}, 2_500)
      assert %{rate_bp: 0, tax_cents: 0, reverse_charge?: false} = no_row

      countryless = Tax.quote(%{}, 2_500)
      assert %{rate_bp: 0, tax_cents: 0, reverse_charge?: false} = countryless
    end

    test "the row's tax figures resolve at charge time — a business VAT number zeroes the gross" do
      {org, setting} =
        charged_setting!(%{
          billing_country: "DE",
          customer_type: :business,
          vat_number: "DE123456789"
        })

      # FIFO expectations: the inline draft expect (asserting the
      # zeroed gross) runs first, the finalize expect second.
      expect(Req, :post, 1, fn _req, opts ->
        assert opts[:url] == "/v1/orders/"
        # Reverse charge: the gross IS the net — VAT zeroed by the
        # evidence, never by a stored rate.
        assert opts[:json]["amount"] == 2_500

        {:ok, %Req.Response{status: 200, body: %{"id" => @order_id, "subtotal_amount" => 2_500}}}
      end)

      stub_finalize(fn ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => @order_id, "status" => "paid", "subtotal_amount" => 2_500}
         }}
      end)

      assert {:ok, :completed, topup} = Billing.start_auto_recharge(org, setting)

      assert topup.tax_rate_bp == 0
      assert topup.tax_cents == 0
      assert topup.reverse_charge? == true
    end
  end
end
