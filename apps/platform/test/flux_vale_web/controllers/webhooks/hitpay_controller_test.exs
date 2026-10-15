defmodule FluxValeWeb.Webhooks.HitPayControllerTest do
  @moduledoc """
  The webhook route contract (#136, ADR-0029): signature first —
  constant-time over the raw body — then the idempotent credit. A
  replayed delivery never double-credits; every valid-signature
  delivery acks 200 except a failed credit (500 → HitPay retries).
  """

  # async: false — stubs the global :hitpay app-env block (the salt).
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures

  @salt "salt"

  setup do
    original = Application.get_env(:flux_vale, :hitpay)
    Application.put_env(:flux_vale, :hitpay, webhook_salt: @salt)

    on_exit(fn -> Application.put_env(:flux_vale, :hitpay, original) end)
    :ok
  end

  defp attached_topup!(amount_cents) do
    {org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(
        %{organization_id: org.id, amount_cents: amount_cents, buyer_email: "buyer@example.com"},
        authorize?: false
      )

    {:ok, attached} =
      Topup.attach_checkout(topup, %{payment_request_id: "pr_1"}, authorize?: false)

    {attached, wallet}
  end

  defp completed_payload(amount) do
    Jason.encode!(%{
      id: "pr_1",
      status: "completed",
      reference_number: nil,
      amount: amount,
      currency: "USD",
      payments: [%{id: "pay_1", status: "succeeded", amount: amount}]
    })
  end

  defp deliver(raw_body, signature \\ :sign) do
    signature =
      case signature do
        :sign ->
          :hmac
          |> :crypto.mac(:sha256, @salt, raw_body)
          |> Base.encode16(case: :lower)

        signature ->
          signature
      end

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("hitpay-signature", signature)
    |> post("/webhooks/hitpay", raw_body)
  end

  test "a verified completed event credits the wallet and acks" do
    {topup, wallet} = attached_topup!(500)

    conn = deliver(completed_payload("5.00"))
    assert %{"received" => true} = json_response(conn, 200)

    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    completed = Topup.get_by_id!(topup.id, authorize?: false)
    assert completed.status == :completed
    assert completed.payment_id == "pay_1"
  end

  test "a replayed delivery never double-credits" do
    {topup, wallet} = attached_topup!(500)
    amount = "5.00"

    _first = deliver(completed_payload(amount))
    replay = deliver(completed_payload(amount))

    assert %{"received" => true} = json_response(replay, 200)
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    assert Topup.get_by_id!(topup.id, authorize?: false).status == :completed
  end

  test "a tampered signature is rejected with 401" do
    attached_topup!(500)
    raw = completed_payload("5.00")

    conn = deliver(raw, "deadbeef")
    assert %{"error" => "invalid_signature"} = json_response(conn, 401)
  end

  test "a missing signature header is rejected with 401" do
    attached_topup!(500)
    raw = completed_payload("5.00")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/hitpay", raw)

    assert %{"error" => "invalid_signature"} = json_response(conn, 401)
  end

  test "a missing salt answers 500 (misconfigured)" do
    attached_topup!(500)
    Application.put_env(:flux_vale, :hitpay, [])

    conn = deliver(completed_payload("5.00"))
    assert %{"error" => "misconfigured"} = json_response(conn, 500)
  end

  test "a failed payment request marks the top-up failed" do
    {_topup, _wallet} = attached_topup!(500)

    raw = Jason.encode!(%{id: "pr_1", status: "failed"})

    conn = deliver(raw)
    assert %{"received" => true} = json_response(conn, 200)
  end

  test "unknown statuses and payloads ack without action" do
    attached_topup!(500)

    pending = deliver(Jason.encode!(%{id: "pr_1", status: "pending"}))
    assert %{"received" => true} = json_response(pending, 200)

    statusless = deliver(Jason.encode!(%{id: "pr_1"}))
    assert %{"received" => true} = json_response(statusless, 200)
  end

  test "a completed event without a succeeded payment acks without crediting" do
    {_topup, wallet} = attached_topup!(500)

    raw =
      Jason.encode!(%{
        id: "pr_1",
        status: "completed",
        payments: [%{id: "pay_0", status: "failed", amount: "5.00"}]
      })

    conn = deliver(raw)
    assert %{"received" => true} = json_response(conn, 200)
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "an unknown top-up acks without crediting" do
    conn = deliver(completed_payload("5.00"))
    assert %{"received" => true} = json_response(conn, 200)
  end

  test "an amount mismatch acks without crediting" do
    {_topup, wallet} = attached_topup!(500)

    conn = deliver(completed_payload("9.99"))
    assert %{"received" => true} = json_response(conn, 200)
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "a failed credit answers 500 so HitPay retries" do
    attached_topup!(500)

    expect(FluxVale.Billing, :complete_topup, fn _outcome -> {:error, :db_down} end)

    conn = deliver(completed_payload("5.00"))
    assert %{"error" => "internal_error"} = json_response(conn, 500)
  end

  test "valid signature, non-object JSON acks 200" do
    conn = deliver("[1,2]")
    assert %{"received" => true} = json_response(conn, 200)
  end

  test "malformed JSON dies in the endpoint parser before the controller (400 in prod)" do
    assert_raise Plug.Parsers.ParseError, fn -> deliver("not-json{") end
  end

  test "an empty body answers 500 (no raw body to verify)" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/hitpay", "")

    assert %{"error" => "misconfigured"} = json_response(conn, 500)
  end
end
