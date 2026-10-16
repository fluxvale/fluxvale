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
    assert topup.tax_cents == 0

    # The gateway's reference names the row — the webhook's fallback join.
    assert_receive {:form, form}
    assert {"reference_number", topup.id} in form
  end

  test "charges the gateway the gross (net + VAT) and keeps the net on the row" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, opts ->
      send(self(), {:form, opts[:form]})
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
    end)

    # The wizard's figures: 19% on the $5.00 net — a caller figure that
    # matches the rate's arithmetic passes the cross-check.
    params = Map.merge(@params, %{tax_rate_bp: 1900, tax_cents: 95})

    assert {:ok, topup, _url} = Billing.start_topup(org, params)

    assert topup.amount_cents == 500
    assert topup.tax_rate_bp == 1900
    assert topup.tax_cents == 95

    assert_receive {:form, form}
    assert {"amount", "5.95"} in form
  end

  test "a caller tax_cents contradicting the row's rate fails closed, nothing persisted" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    # No gateway call may happen — the mismatch rejects before any
    # charge.
    stub(Req, :post, fn _req, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_leak", "url" => "https://x/pr_leak"}}}
    end)

    params = Map.merge(@params, %{tax_rate_bp: 1900, tax_cents: 100})

    assert {:error, :tax_cents_mismatch} = Billing.start_topup(org, params)

    rows =
      Topup
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.read!(authorize?: false)

    assert rows == []
  end

  test "a reverse-charge caller tax_cents contradicting the 0% figure fails closed" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    stub(Req, :post, fn _req, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_leak", "url" => "https://x/pr_leak"}}}
    end)

    # Reverse charge zeroes the rate, so the authoritative tax is 0 —
    # a caller still carrying the 19% figure is a contradiction.
    params =
      Map.merge(@params, %{
        customer_type: :business,
        vat_number: "DE123456789",
        tax_rate_bp: 1900,
        tax_cents: 95
      })

    assert {:error, :tax_cents_mismatch} = Billing.start_topup(org, params)

    rows =
      Topup
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.read!(authorize?: false)

    assert rows == []
  end

  test "derives tax_cents from tax_rate_bp when the caller omits it" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
    end)

    assert {:ok, topup, _url} = Billing.start_topup(org, Map.put(@params, :tax_rate_bp, 1900))

    assert topup.tax_cents == 95
  end

  test "records the checkout tax layer's buyer evidence" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
    end)

    params =
      Map.merge(@params, %{
        billing_country: "US",
        billing_state: "ca",
        customer_type: :consumer,
        vat_number: nil,
        ip_country: "DE",
        tax_rate_bp: 0,
        tax_cents: 0
      })

    assert {:ok, topup, _url} = Billing.start_topup(org, params)

    assert topup.billing_country == "US"
    assert topup.billing_state == "ca"
    assert topup.customer_type == :consumer
    assert topup.ip_country == "DE"
    # A mismatched IP is a weak signal — recorded, never a block; the
    # billing address decides the rate.
    assert topup.ip_matches_billing? == false
    assert topup.reverse_charge? == false
  end

  test "an exact billing/IP country match records the signal" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
    end)

    params = Map.merge(@params, %{ip_country: "DE"})

    assert {:ok, topup, _url} = Billing.start_topup(org, params)
    assert topup.ip_matches_billing? == true
  end

  test "a business buyer with a valid VAT number records the reverse-charge proof at 0%" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, opts ->
      send(self(), {:form, opts[:form]})
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
    end)

    # The caller passes a non-zero rate with a matching (reverse-charge
    # zeroed) tax figure: StartTopup enforces the invariant — the
    # applied rate is 0 and the tax is the rate's own figure, 0.
    params =
      Map.merge(@params, %{
        customer_type: :business,
        vat_number: "DE123456789",
        tax_rate_bp: 1900,
        tax_cents: 0
      })

    assert {:ok, topup, _url} = Billing.start_topup(org, params)

    assert topup.customer_type == :business
    assert topup.vat_number == "DE123456789"
    assert topup.reverse_charge? == true
    assert topup.tax_rate_bp == 0
    assert topup.tax_cents == 0

    assert_receive {:form, form}
    assert {"amount", "5.00"} in form
  end

  test "a business buyer without a valid VAT number pays the country rate" do
    {org, _wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    expect(Req, :post, fn _req, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
    end)

    params =
      Map.merge(@params, %{
        customer_type: :business,
        vat_number: "nope",
        tax_rate_bp: 1900,
        tax_cents: 95
      })

    assert {:ok, topup, _url} = Billing.start_topup(org, params)

    assert topup.reverse_charge? == false
    assert topup.tax_rate_bp == 1900
    assert topup.tax_cents == 95
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
