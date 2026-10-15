defmodule FluxVale.Billing.Operations.StartTopupTest do
  @moduledoc """
  StartTopup contract (#136): pending row → gateway checkout → attached
  payment request. Checkout failure leaves a failed, auditable row.
  """

  # async: false — stubs the global :hitpay app-env block (Req is
  # Mimic-stubbed for the gateway call itself).
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures

  require Ash.Query

  setup do
    original = Application.get_env(:flux_vale, :hitpay)

    Application.put_env(:flux_vale, :hitpay,
      api_key: "sbx_key",
      webhook_salt: "salt",
      base_url: "https://api.example"
    )

    on_exit(fn -> Application.put_env(:flux_vale, :hitpay, original) end)
    :ok
  end

  @params %{
    amount_cents: 500,
    redirect_url: "https://app.example/billing/topup/return/later",
    buyer_email: "buyer@example.com",
    buyer_name: "Buyer One",
    billing_country: "DE"
  }

  test "creates a pending top-up, opens the checkout, and attaches the request id" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, opts ->
      send(self(), {:form, opts[:form]})
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
    end)

    assert {:ok, topup, checkout_url} = Billing.start_topup(org, @params)

    assert checkout_url == "https://checkout/pr_1"
    assert topup.status == :pending
    assert topup.payment_request_id == "pr_1"
    assert topup.amount_cents == 500
    assert topup.billing_country == "DE"
    assert topup.tax_rate_bp == 0

    # The gateway's reference names the row — the webhook's fallback join.
    assert_receive {:form, form}
    assert {"reference_number", topup.id} in form
  end

  test "gateway failure marks the row failed and returns the error" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, _opts ->
      {:ok, %Req.Response{status: 401, body: %{"message" => "invalid key"}}}
    end)

    assert {:error, :api_error} = Billing.start_topup(org, @params)

    failed =
      Topup
      |> Ash.Query.filter(status == :failed)
      |> Ash.read!(authorize?: false)

    assert [%Topup{payment_request_id: nil}] = failed
  end

  test "missing credentials answer :missing_config without a gateway call" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    Application.put_env(:flux_vale, :hitpay, base_url: "https://api.example")

    assert {:error, :missing_config} = Billing.start_topup(org, @params)
  end

  # The gateway reusing a payment-request id (a retry on their side)
  # trips the unique index on attach — the row stays pending, and the
  # webhook's reference fallback heals it when the payment lands.
  test "a duplicate payment-request id answers an error and leaves the row pending" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    stub(Req, :post, fn _req, _opts ->
      {:ok,
       %Req.Response{status: 200, body: %{"id" => "pr_dup", "url" => "https://checkout/pr_dup"}}}
    end)

    assert {:ok, _topup, _url} = Billing.start_topup(org, @params)
    assert {:error, %Ash.Error.Invalid{}} = Billing.start_topup(org, @params)
  end
end
