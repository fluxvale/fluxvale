defmodule FluxValeWeb.Webhooks.PolarControllerTest do
  @moduledoc """
  The webhook route contract (#377, ADR-0029): signature first — the
  three Standard Webhooks headers joined in signed order,
  constant-time over the raw body — then the idempotent credit.
  Both #377 contract points pin here: the amount reads
  `subtotal_amount` — exactly what the checkout set, discount-
  invariant where `total_amount` diverges under discounts and
  Polar's tax carve-out — and idempotency converges on
  `polar:<checkout_id>`. A replayed delivery never
  double-credits; every valid-signature delivery acks 200 except a
  failed credit (500 → Polar retries).
  """

  # async: false — stubs the global :polar app-env block (the secret).
  use FluxValeWeb.ConnCase, async: false
  use Mimic

  alias FluxVale.Billing
  alias FluxVale.Billing.AutoRechargeSetting
  alias FluxVale.Billing.Topup
  alias FluxVale.TestSupport.BillingFixtures

  # Fixture signing material — never a real secret.
  @key "polar_test_signing_key"
  @secret "whsec_" <> Base.encode64(@key)

  setup do
    original = Application.get_env(:flux_vale, :polar)
    Application.put_env(:flux_vale, :polar, webhook_secret: @secret)

    on_exit(fn -> Application.put_env(:flux_vale, :polar, original) end)
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
      Topup.attach_checkout(topup, %{payment_request_id: "co_1"}, authorize?: false)

    {attached, wallet}
  end

  # An auto lane row (#829): origin :auto, the order id (not a
  # checkout id) attached as the payment request.
  defp attached_auto_topup!(order_id, amount_cents) do
    {org, wallet} = BillingFixtures.funded_wallet!(balance_cents: 0)

    {:ok, topup} =
      Topup.create(
        %{organization_id: org.id, amount_cents: amount_cents, origin: :auto},
        authorize?: false
      )

    {:ok, attached} =
      Topup.attach_checkout(topup, %{payment_request_id: order_id}, authorize?: false)

    {attached, wallet}
  end

  # Arms the staged lane for a REAL StartAutoRecharge charge
  # (Req-stubbed — no live Polar call): {org, setting}.
  defp charged_setting! do
    original_polar = Application.get_env(:flux_vale, :polar)
    original_provider = Application.get_env(:flux_vale, :payments_provider)
    original_gate = Application.get_env(:flux_vale, :auto_recharge)

    Application.put_env(:flux_vale, :polar,
      access_token: "tok",
      webhook_secret: @secret,
      server: "sandbox",
      product_id: "prod_1"
    )

    Application.put_env(:flux_vale, :payments_provider, FluxVale.Billing.Providers.Polar)
    Application.put_env(:flux_vale, :auto_recharge, charge_mode: true)

    on_exit(fn ->
      Application.put_env(:flux_vale, :polar, original_polar)
      Application.put_env(:flux_vale, :payments_provider, original_provider)
      Application.put_env(:flux_vale, :auto_recharge, original_gate)
    end)

    # PH: an unpriced market — the gross IS the net (2500¢, no VAT).
    {org, owner} = BillingFixtures.grant_free_org!()

    {:ok, bare} = AutoRechargeSetting.create(%{organization_id: org.id}, authorize?: false)

    {:ok, with_evidence} =
      Billing.set_auto_recharge_setting(bare, %{billing_country: "PH"}, actor: owner)

    {:ok, setting} =
      with_evidence
      |> Ash.Changeset.for_update(:set_method_status, %{
        payment_method_status: :attached,
        provider_customer_id: "cus_1"
      })
      |> Ash.update(authorize?: false)

    {org, setting}
  end

  defp order_paid_payload(subtotal_cents, opts \\ []) do
    # total_amount deliberately differs from the subtotal — they'd
    # match under tax-inclusive-no-discount, but Polar's tax carve-out
    # and applied discounts both make total diverge; subtotal_amount
    # is the discount-invariant amount the checkout set (contract
    # point 1).
    base = %{
      id: "ord_1",
      checkout_id: "co_1",
      subtotal_amount: subtotal_cents,
      total_amount: subtotal_cents - 50
    }

    data =
      case Keyword.fetch(opts, :topup_id) do
        {:ok, topup_id} -> Map.put(base, :metadata, %{topup_id: topup_id})
        :error -> base
      end

    Jason.encode!(%{type: "order.paid", data: data})
  end

  # The off-session delivery (#829): no checkout_id — the order id is
  # the payment identity, so the payload carries only it.
  defp draft_order_paid_payload(subtotal_cents, order_id, opts \\ []) do
    base = %{id: order_id, subtotal_amount: subtotal_cents}

    data =
      case Keyword.fetch(opts, :topup_id) do
        {:ok, topup_id} -> Map.put(base, :metadata, %{topup_id: topup_id})
        :error -> base
      end

    Jason.encode!(%{type: "order.paid", data: data})
  end

  defp deliver(raw_body, opts \\ []) do
    id = "msg_polar_1"
    ts = Keyword.get_lazy(opts, :timestamp, &now_ts/0)
    signature = Keyword.get_lazy(opts, :signature, fn -> sign(id, ts, raw_body) end)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("webhook-id", id)
    |> put_req_header("webhook-timestamp", ts)
    |> put_req_header("webhook-signature", signature)
    |> post("/webhooks/polar", raw_body)
  end

  # A valid delivery minus exactly one of the three headers — none
  # may reach verify.
  defp deliver_without(header, raw_body) do
    id = "msg_polar_1"
    ts = now_ts()

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("webhook-id", id)
    |> put_req_header("webhook-timestamp", ts)
    |> put_req_header("webhook-signature", sign(id, ts, raw_body))
    |> delete_req_header(header)
    |> post("/webhooks/polar", raw_body)
  end

  # Standard Webhooks signing over "<id>.<ts>.<body>" with a real
  # HMAC — the same math the adapter runs.
  defp sign(id, ts, body) do
    mac = :crypto.mac(:hmac, :sha256, @key, id <> "." <> ts <> "." <> body)
    "v1," <> Base.encode64(mac)
  end

  defp now_ts do
    seconds = System.os_time(:second)
    Integer.to_string(seconds)
  end

  defp wallet_of_org(org) do
    {:ok, wallet} = Billing.ensure_wallet(org)
    wallet
  end

  test "a verified order.paid credits the wallet and acks" do
    {topup, wallet} = attached_topup!(500)

    conn = deliver(order_paid_payload(500, topup_id: topup.id))
    assert %{"received" => true} = json_response(conn, 200)

    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    completed = Topup.get_by_id!(topup.id, authorize?: false)
    assert completed.status == :completed
    assert completed.payment_id == "co_1"
  end

  # #377: the outcome mail rides the fresh transition — the replayed
  # delivery mails nothing new.
  test "a verified order.paid mails the outcome exactly once" do
    {topup, _wallet} = attached_topup!(500)

    conn = deliver(order_paid_payload(500, topup_id: topup.id))
    assert %{"received" => true} = json_response(conn, 200)

    assert_receive {:email, %Swoosh.Email{text_body: body}}
    assert body =~ "balance is now $5.00"

    replay = deliver(order_paid_payload(500, topup_id: topup.id))
    assert %{"received" => true} = json_response(replay, 200)
    refute_received {:email, _email}
  end

  test "the credit outcome pins both contract points (#377)" do
    {topup, _wallet} = attached_topup!(500)
    parent = self()

    expect(FluxVale.Billing, :complete_topup, fn outcome ->
      send(parent, {:outcome, outcome})
      {:ok, :already_completed}
    end)

    conn = deliver(order_paid_payload(500, topup_id: topup.id))
    assert %{"received" => true} = json_response(conn, 200)

    assert_received {:outcome, outcome}

    # Amount from subtotal_amount — exactly the amount the checkout
    # set, discount-invariant (total_amount diverges under discounts
    # and Polar's tax carve-out); the checkout id is the payment
    # identity everywhere; idempotency converges on
    # polar:<checkout_id> — identical to the reconcile path.
    assert outcome == %{
             payment_request_id: "co_1",
             payment_id: "co_1",
             amount_cents: 500,
             idempotency_key: "polar:co_1",
             topup_id: topup.id
           }
  end

  test "a replayed delivery never double-credits" do
    {topup, wallet} = attached_topup!(500)

    _first = deliver(order_paid_payload(500, topup_id: topup.id))
    replay = deliver(order_paid_payload(500, topup_id: topup.id))

    assert %{"received" => true} = json_response(replay, 200)
    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    assert Topup.get_by_id!(topup.id, authorize?: false).status == :completed
  end

  test "an already-completed replay acks 200" do
    attached_topup!(500)

    expect(FluxVale.Billing, :complete_topup, fn _outcome -> {:ok, :already_completed} end)

    conn = deliver(order_paid_payload(500))
    assert %{"received" => true} = json_response(conn, 200)
  end

  test "an amount mismatch acks without crediting" do
    {_topup, wallet} = attached_topup!(500)

    conn = deliver(order_paid_payload(999))
    assert %{"received" => true} = json_response(conn, 200)
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "missing metadata still resolves by payment_request_id — the outcome carries no topup_id" do
    attached_topup!(500)
    parent = self()

    expect(FluxVale.Billing, :complete_topup, fn outcome ->
      send(parent, {:outcome, outcome})
      {:ok, :already_completed}
    end)

    conn = deliver(order_paid_payload(500))
    assert %{"received" => true} = json_response(conn, 200)

    assert_received {:outcome, outcome}

    assert outcome == %{
             payment_request_id: "co_1",
             payment_id: "co_1",
             amount_cents: 500,
             idempotency_key: "polar:co_1"
           }

    refute Map.has_key?(outcome, :topup_id)
  end

  test "a delivery without metadata credits by payment_request_id alone" do
    {topup, wallet} = attached_topup!(500)

    conn = deliver(order_paid_payload(500))
    assert %{"received" => true} = json_response(conn, 200)

    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)
    assert Topup.get_by_id!(topup.id, authorize?: false).status == :completed
  end

  # ── The off-session order-id arm (#829 S3) ──

  test "an off-session order.paid resolves by metadata.topup_id, keying the order id space" do
    {topup, _wallet} = attached_auto_topup!("ord_9", 500)
    parent = self()

    expect(FluxVale.Billing, :complete_topup, fn outcome ->
      send(parent, {:outcome, outcome})
      {:ok, :already_completed}
    end)

    conn = deliver(draft_order_paid_payload(500, "ord_9", topup_id: topup.id))
    assert %{"received" => true} = json_response(conn, 200)

    assert_received {:outcome, outcome}

    # No checkout session ever existed on this lane: the ORDER id is
    # the payment identity — request id, payment id, and the ledger
    # key, a different id space from a checkout delivery's
    # `polar:co_…` (the two can never collide).
    assert outcome == %{
             payment_request_id: "ord_9",
             payment_id: "ord_9",
             amount_cents: 500,
             idempotency_key: "polar:ord_9",
             topup_id: topup.id
           }
  end

  test "an off-session order.paid without metadata credits by the order id alone" do
    {topup, wallet} = attached_auto_topup!("ord_9", 500)

    conn = deliver(draft_order_paid_payload(500, "ord_9"))
    assert %{"received" => true} = json_response(conn, 200)

    assert {:ok, 500} = Billing.balance(wallet, authorize?: false)

    completed = Topup.get_by_id!(topup.id, authorize?: false)
    assert completed.status == :completed
    assert completed.payment_id == "ord_9"
  end

  # The launch-path inertness (plan S3): a checkout order's
  # payment_request_id is a checkout session id, so an order-id
  # delivery for a manual row resolves nothing — the arm no-ops on
  # every launch-path delivery.
  test "an order-id delivery matching no row acks without crediting" do
    {_topup, wallet} = attached_topup!(500)

    conn = deliver(draft_order_paid_payload(500, "ord_nobody"))
    assert %{"received" => true} = json_response(conn, 200)

    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  # The staged lane end to end: StartAutoRecharge (Req-stubbed — no
  # live Polar call) creates the pending row and finalizes; the
  # webhook — never the starter — posts the credit, exactly once,
  # with the origin on the analytics event (still no amounts).
  test "an auto-recharge attempt's order.paid credits exactly once; the replay acks dry" do
    {org, setting} = charged_setting!()
    gross = 2_500

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/"
      assert opts[:json]["amount"] == gross

      {:ok, %Req.Response{status: 200, body: %{"id" => "ord_1", "subtotal_amount" => gross}}}
    end)

    expect(Req, :post, 1, fn _req, opts ->
      assert opts[:url] == "/v1/orders/ord_1/finalize"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => "ord_1", "status" => "paid", "subtotal_amount" => gross}
       }}
    end)

    assert {:ok, :completed, topup} = Billing.start_auto_recharge(org, setting)
    assert topup.payment_request_id == "ord_1"

    # The starter never credited.
    wallet = wallet_of_org(org)
    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)

    org_id = topup.organization_id

    expect(FluxVale.Analytics, :capture, 1, fn "wallet topped up", ^org_id, props ->
      assert props == %{provider: "polar", origin: :auto}
      :ok
    end)

    first = deliver(draft_order_paid_payload(gross, "ord_1", topup_id: topup.id))
    assert %{"received" => true} = json_response(first, 200)

    # The credit posts the NET (the gross guard compared 2500 =
    # 2500 net + 0 VAT — PH's unpriced market).
    assert {:ok, 2_500} = Billing.balance(wallet, authorize?: false)
    completed = Topup.get_by_id!(topup.id, authorize?: false)
    assert completed.status == :completed
    assert completed.payment_id == "ord_1"

    # The idempotent replay: same ledger key `polar:ord_1`, answers
    # :already_completed — no second credit, no second event.
    replay = deliver(draft_order_paid_payload(gross, "ord_1", topup_id: topup.id))
    assert %{"received" => true} = json_response(replay, 200)

    assert {:ok, 2_500} = Billing.balance(wallet, authorize?: false)
  end

  test "an order.paid without a usable checkout id or subtotal acks without crediting" do
    {_topup, wallet} = attached_topup!(500)

    # No checkout id AND no order id: neither arm of the payment
    # identity can resolve — the :none ack (launch traffic can never
    # reach the order arm through it, #829 S3).
    neither_id =
      Jason.encode!(%{type: "order.paid", data: %{subtotal_amount: 500}})

    conn = deliver(neither_id)
    assert %{"received" => true} = json_response(conn, 200)

    string_subtotal =
      Jason.encode!(%{
        type: "order.paid",
        data: %{id: "ord_1", checkout_id: "co_1", subtotal_amount: "500"}
      })

    string_conn = deliver(string_subtotal)
    assert %{"received" => true} = json_response(string_conn, 200)

    assert {:ok, 0} = Billing.balance(wallet, authorize?: false)
  end

  test "customer.state_changed acks without touching the credit path" do
    reject(FluxVale.Billing, :complete_topup, 1)

    raw =
      Jason.encode!(%{
        type: "customer.state_changed",
        data: %{id: "cus_1", status: "active"}
      })

    conn = deliver(raw)
    assert %{"received" => true} = json_response(conn, 200)
  end

  test "unknown event types ack without action" do
    reject(FluxVale.Billing, :complete_topup, 1)

    raw =
      Jason.encode!(%{
        type: "subscription.created",
        data: %{id: "sub_1"}
      })

    conn = deliver(raw)
    assert %{"received" => true} = json_response(conn, 200)
  end

  test "a payload without a type field acks without action" do
    reject(FluxVale.Billing, :complete_topup, 1)

    conn = deliver(Jason.encode!(%{data: %{id: "ord_1"}}))
    assert %{"received" => true} = json_response(conn, 200)
  end

  test "a tampered signature is rejected with 401" do
    attached_topup!(500)

    conn = deliver(order_paid_payload(500), signature: "v1,deadbeef")
    assert %{"error" => "invalid_signature"} = json_response(conn, 401)
  end

  test "a missing signature entry is rejected with 401" do
    attached_topup!(500)

    conn = deliver(order_paid_payload(500), signature: "")
    assert %{"error" => "invalid_signature"} = json_response(conn, 401)
  end

  test "a stale timestamp is rejected with 401" do
    attached_topup!(500)

    stale = Integer.to_string(System.os_time(:second) - 3600)
    conn = deliver(order_paid_payload(500), timestamp: stale)
    assert %{"error" => "invalid_signature"} = json_response(conn, 401)
  end

  test "a delivery missing any of the three headers is rejected with 401" do
    attached_topup!(500)
    raw = order_paid_payload(500)

    for header <- ["webhook-id", "webhook-timestamp", "webhook-signature"] do
      rejected = deliver_without(header, raw)
      assert %{"error" => "invalid_signature"} = json_response(rejected, 401)
    end
  end

  test "a missing secret answers 500 (misconfigured)" do
    attached_topup!(500)
    Application.put_env(:flux_vale, :polar, [])

    conn = deliver(order_paid_payload(500))
    assert %{"error" => "misconfigured"} = json_response(conn, 500)
  end

  test "a failed credit answers 500 so Polar retries" do
    attached_topup!(500)

    expect(FluxVale.Billing, :complete_topup, fn _outcome -> {:error, :db_down} end)

    conn = deliver(order_paid_payload(500))
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
      |> post("/webhooks/polar", "")

    assert %{"error" => "misconfigured"} = json_response(conn, 500)
  end
end
