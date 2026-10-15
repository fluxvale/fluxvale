defmodule FluxVale.Billing.Operations.ReconcileTopupTest do
  @moduledoc """
  ReconcileTopup contract (#137): the Confirmation step's fallback —
  a completed gateway request completes the row through the same
  idempotent credit the webhook uses; terminal failures fail it;
  anything else leaves the row for the webhook.
  """

  # async: false — stubs the global :hitpay app-env block.
  use FluxVale.DataCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures

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

  defp topup!(amount_cents) do
    {org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(%{organization_id: org.id, amount_cents: amount_cents}, authorize?: false)

    {:ok, attached} =
      Topup.attach_checkout(topup, %{payment_request_id: "pr_1"}, authorize?: false)

    {attached, wallet}
  end

  defp gateway_payment(status, payment_status \\ "succeeded") do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "id" => "pr_1",
         "status" => status,
         "amount" => "5.00",
         "payments" => [%{"id" => "pay_1", "status" => payment_status, "amount" => "5.00"}]
       }
     }}
  end

  test "a completed gateway request credits the wallet and completes the row" do
    {_topup, wallet} = topup!(500)
    expect(Req, :get, fn _req, _opts -> gateway_payment("completed") end)

    assert {:ok, %Topup{status: :completed}} = Billing.reconcile_topup("pr_1")
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
  end

  test "an already-webhook-completed row answers :already_completed without re-crediting" do
    {_topup, wallet} = topup!(500)

    {:ok, _completed} =
      Billing.complete_topup(%{
        payment_request_id: "pr_1",
        payment_id: "pay_1",
        amount_cents: 500,
        idempotency_key: "hitpay:pay_1"
      })

    # fetch still runs (reconcile is gateway-first), the credit doesn't
    expect(Req, :get, fn _req, _opts -> gateway_payment("completed") end)

    assert {:ok, :already_completed} = Billing.reconcile_topup("pr_1")
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
  end

  test "a pending gateway request leaves the row pending" do
    {_topup, _wallet} = topup!(500)
    expect(Req, :get, fn _req, _opts -> gateway_payment("pending") end)

    assert {:ok, :pending} = Billing.reconcile_topup("pr_1")
  end

  test "a completed request without a succeeded charge has nothing to reconcile" do
    {_topup, wallet} = topup!(500)
    expect(Req, :get, fn _req, _opts -> gateway_payment("completed", "failed") end)

    assert {:ok, :pending} = Billing.reconcile_topup("pr_1")
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "a succeeded charge without a usable id is not a charge (webhook parity)" do
    {_topup, wallet} = topup!(500)

    expect(Req, :get, fn _req, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "id" => "pr_1",
           "status" => "completed",
           "amount" => "5.00",
           "payments" => [%{"id" => nil, "status" => "succeeded", "amount" => "5.00"}]
         }
       }}
    end)

    assert {:ok, :pending} = Billing.reconcile_topup("pr_1")
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "a terminal failure fails the row" do
    {_topup, wallet} = topup!(500)
    expect(Req, :get, fn _req, _opts -> gateway_payment("failed") end)

    assert {:ok, %Topup{status: :failed}} = Billing.reconcile_topup("pr_1")
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "a gateway error leaves the row pending" do
    {_topup, _wallet} = topup!(500)
    expect(Req, :get, fn _req, _opts -> {:error, %Req.TransportError{reason: :timeout}} end)

    assert {:error, :network_error} = Billing.reconcile_topup("pr_1")
  end
end
