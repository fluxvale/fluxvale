defmodule FluxVale.Billing.Providers.HitPayTest do
  @moduledoc """
  HitPay adapter contract (#136, ADR-0029): checkout creation over the
  form-encoded Payment Request API, constant-time webhook verification
  with the per-webhook salt, fetch normalization. HTTP is Mimic-stubbed
  (v1's Dodo pattern) — the adapter's job is translating wires into the
  three atoms, not talking to the sandbox.
  """

  # async: false — tests stub the global :hitpay app-env block (capture
  # and restore below); siblings must not read a half-stubbed config.
  use ExUnit.Case, async: false
  use Mimic

  alias FluxVale.Billing.Providers.HitPay

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

  @request %{
    amount_cents: 500,
    currency: "USD",
    reference: "topup_1",
    redirect_url: "https://app.example/billing/topup/return/topup_1",
    email: "buyer@example.com",
    name: "Buyer One"
  }

  describe "create_checkout/2" do
    test "posts a form-encoded payment request and returns the handle" do
      expect(Req, :post, fn req, opts ->
        assert req.options[:base_url] == "https://api.example"
        assert Req.Request.get_header(req, "x-business-api-key") == ["sbx_key"]

        assert opts[:form] == [
                 {"email", "buyer@example.com"},
                 {"name", "Buyer One"},
                 {"amount", "5.00"},
                 {"currency", "USD"},
                 {"reference_number", "topup_1"},
                 {"redirect_url", "https://app.example/billing/topup/return/topup_1"},
                 {"allow_repeated_payments", "false"}
               ]

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
      end)

      assert {:ok, %{payment_request_id: "pr_1", checkout_url: "https://checkout/pr_1"}} =
               HitPay.create_checkout(@request, [])
    end

    test "omits empty buyer fields and formats odd cents exactly" do
      request = %{@request | amount_cents: 12_345, email: nil, name: ""}

      expect(Req, :post, fn _req, opts ->
        assert opts[:form] == [
                 {"amount", "123.45"},
                 {"currency", "USD"},
                 {"reference_number", "topup_1"},
                 {"redirect_url", "https://app.example/billing/topup/return/topup_1"},
                 {"allow_repeated_payments", "false"}
               ]

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
      end)

      assert {:ok, _handle} = HitPay.create_checkout(request, [])
    end

    test "opts override the app-env block (sandbox pinning)" do
      expect(Req, :post, fn req, _opts ->
        assert req.options[:base_url] == "https://pinned.example"

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "pr_1", "url" => "https://checkout/pr_1"}}}
      end)

      assert {:ok, _handle} = HitPay.create_checkout(@request, base_url: "https://pinned.example")
    end

    test "answers :missing_config without an api key" do
      Application.put_env(:flux_vale, :hitpay, base_url: "https://api.example")

      assert {:error, :missing_config} = HitPay.create_checkout(@request, [])
    end

    test "maps non-2xx to :api_error" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 401, body: %{"message" => "invalid key"}}}
      end)

      assert {:error, :api_error} = HitPay.create_checkout(@request, [])
    end

    test "maps transport failures to :network_error" do
      expect(Req, :post, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :network_error} = HitPay.create_checkout(@request, [])
    end

    test "answers :invalid_response when the body lacks id/url" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1"}}}
      end)

      assert {:error, :invalid_response} = HitPay.create_checkout(@request, [])
    end
  end

  describe "verify_webhook/2" do
    test "accepts a correctly signed body" do
      signature = sign("salt", ~s({"id":"pr_1"}))
      assert :ok = HitPay.verify_webhook(~s({"id":"pr_1"}), signature)
    end

    test "rejects a tampered body" do
      signature = sign("salt", ~s({"id":"pr_1"}))
      assert {:error, :signature_mismatch} = HitPay.verify_webhook(~s({"id":"pr_2"}), signature)
    end

    test "rejects an absent signature" do
      assert {:error, :missing_signature} = HitPay.verify_webhook(~s({"id":"pr_1"}), nil)
    end

    test "answers :missing_config without a salt" do
      Application.put_env(:flux_vale, :hitpay, api_key: "sbx_key")

      assert {:error, :missing_config} = HitPay.verify_webhook(~s({"id":"pr_1"}), "aa")
    end
  end

  describe "fetch_payment/1" do
    test "normalizes a payment request" do
      body = %{
        "id" => "pr_1",
        "status" => "completed",
        "amount" => "100.00",
        "payments" => [%{"id" => "pay_1", "status" => "succeeded", "amount" => "100.00"}]
      }

      expect(Req, :get, fn req, opts ->
        assert req.options[:base_url] == "https://api.example"
        assert Req.Request.get_header(req, "x-business-api-key") == ["sbx_key"]
        assert opts[:url] == "/v1/payment-requests/pr_1"
        {:ok, %Req.Response{status: 200, body: body}}
      end)

      assert {:ok, payment} = HitPay.fetch_payment("pr_1")

      assert payment == %{
               payment_request_id: "pr_1",
               status: :completed,
               amount_cents: 10_000,
               payments: [%{id: "pay_1", status: :succeeded, amount_cents: 10_000}]
             }
    end

    test "accepts whole-dollar amounts and a missing payments list" do
      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "pr_1", "status" => "pending", "amount" => "100"}
         }}
      end)

      assert {:ok, %{amount_cents: 10_000, status: :pending, payments: []}} =
               HitPay.fetch_payment("pr_1")
    end

    test "maps known gateway statuses to atoms; unknown stays :unknown" do
      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "pr_1", "status" => "canceled", "amount" => "1.00"}
         }}
      end)

      assert {:ok, %{status: :cancelled}} = HitPay.fetch_payment("pr_1")

      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "pr_1", "status" => "mysterious", "amount" => "1.00"}
         }}
      end)

      assert {:ok, %{status: :unknown}} = HitPay.fetch_payment("pr_1")
    end

    test "answers :invalid_response for malformed bodies" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"status" => "completed"}}}
      end)

      assert {:error, :invalid_response} = HitPay.fetch_payment("pr_1")

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "amount" => nil}}}
      end)

      assert {:error, :invalid_response} = HitPay.fetch_payment("pr_1")

      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "pr_1", "amount" => "1.00", "payments" => [%{"amount" => "x"}]}
         }}
      end)

      assert {:error, :invalid_response} = HitPay.fetch_payment("pr_1")
    end

    test "answers :missing_config without an api key" do
      Application.put_env(:flux_vale, :hitpay, base_url: "https://api.example")

      assert {:error, :missing_config} = HitPay.fetch_payment("pr_1")
    end

    test "maps API and network failures to their atoms" do
      expect(Req, :get, fn _req, _opts -> {:ok, %Req.Response{status: 404, body: %{}}} end)
      assert {:error, :api_error} = HitPay.fetch_payment("pr_1")

      expect(Req, :get, fn _req, _opts -> {:error, %Req.TransportError{reason: :timeout}} end)
      assert {:error, :network_error} = HitPay.fetch_payment("pr_1")
    end

    test "percent-encodes a hostile id so it cannot retarget the GET" do
      expect(Req, :get, fn _req, opts ->
        assert opts[:url] == "/v1/payment-requests/..%2Fevil%3Fid%3D1"
        {:ok, %Req.Response{status: 200, body: %{"id" => "x", "amount" => "1.00"}}}
      end)

      assert {:ok, _payment} = HitPay.fetch_payment("../evil?id=1")
    end

    test "negative amounts are malformed — Integer.parse drops a -0 sign" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "amount" => "-0.99"}}}
      end)

      assert {:error, :invalid_response} = HitPay.fetch_payment("pr_1")

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "amount" => "-1.00"}}}
      end)

      assert {:error, :invalid_response} = HitPay.fetch_payment("pr_1")
    end

    test "amounts that would round are malformed, not normalized" do
      for amount <- ["5.009", "+5.00", "5.+5", "1.2.3"] do
        expect(Req, :get, fn _req, _opts ->
          {:ok, %Req.Response{status: 200, body: %{"id" => "pr_1", "amount" => amount}}}
        end)

        assert {:error, :invalid_response} = HitPay.fetch_payment("pr_1")
      end
    end
  end

  describe "succeeded_payment/1" do
    test "reads the succeeded charge" do
      payments = [
        %{"id" => "pay_0", "status" => "failed", "amount" => "5.00"},
        %{"id" => "pay_1", "status" => "succeeded", "amount" => "5.00"}
      ]

      assert {:ok, %{id: "pay_1", amount_cents: 500}} = HitPay.succeeded_payment(payments)
    end

    test "answers :none without a succeeded charge, without payments, or with an unusable amount" do
      assert :none =
               HitPay.succeeded_payment([
                 %{"id" => "pay_0", "status" => "failed", "amount" => "5.00"}
               ])

      assert :none = HitPay.succeeded_payment(nil)

      assert :none =
               HitPay.succeeded_payment([
                 %{"id" => "pay_1", "status" => "succeeded", "amount" => "x"}
               ])

      assert :none = HitPay.succeeded_payment([%{"id" => "pay_1", "status" => "succeeded"}])

      assert :none =
               HitPay.succeeded_payment([
                 %{"id" => "pay_1", "status" => "succeeded", "amount" => "-0.99"}
               ])
    end
  end

  test "idempotency_key/1 prefixes the payment id with the provider namespace" do
    assert HitPay.idempotency_key("pay_1") == "hitpay:pay_1"
  end

  defp sign(salt, raw) do
    :hmac
    |> :crypto.mac(:sha256, salt, raw)
    |> Base.encode16(case: :lower)
  end
end
