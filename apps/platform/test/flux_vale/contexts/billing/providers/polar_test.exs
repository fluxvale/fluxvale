defmodule FluxVale.Billing.Providers.PolarTest do
  @moduledoc """
  Polar adapter contract (#377, ADR-0029): checkout creation over the
  JSON Checkout Sessions API, Standard Webhooks verification with
  both key derivations and the timestamp window, fetch
  normalization. HTTP is Mimic-stubbed (the HitPay pattern) — the
  adapter's job is translating wires into the three atoms, not
  talking to the sandbox.
  """

  # async: false — tests stub the global :polar app-env block (capture
  # and restore below); siblings must not read a half-stubbed config.
  use ExUnit.Case, async: false
  use Mimic

  alias FluxVale.Billing.Providers.Polar

  # Fixture secrets — never real values.
  @standard_key "polar_standard_key_bytes"
  @standard_secret "whsec_" <> Base.encode64(@standard_key)
  @legacy_secret "polar_legacy_secret"

  setup do
    original = Application.get_env(:flux_vale, :polar)

    Application.put_env(:flux_vale, :polar,
      access_token: "sbx_token",
      webhook_secret: @standard_secret,
      server: "sandbox",
      product_id: "prod_1"
    )

    on_exit(fn -> Application.put_env(:flux_vale, :polar, original) end)
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
    test "posts a JSON checkout and returns the handle" do
      expect(Req, :post, fn req, opts ->
        assert req.options[:base_url] == "https://sandbox-api.polar.sh"
        assert Req.Request.get_header(req, "authorization") == ["bearer sbx_token"]
        assert opts[:url] == "/v1/checkouts/"

        assert opts[:json] == %{
                 "products" => ["prod_1"],
                 "amount" => 500,
                 "currency" => "usd",
                 "success_url" => "https://app.example/billing/topup/return/topup_1",
                 "metadata" => %{"topup_id" => "topup_1"},
                 "customer_email" => "buyer@example.com",
                 "customer_name" => "Buyer One"
               }

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "co_1", "url" => "https://checkout/co_1"}}}
      end)

      assert {:ok, %{payment_request_id: "co_1", checkout_url: "https://checkout/co_1"}} =
               Polar.create_checkout(@request, [])
    end

    test "omits empty buyer fields — integer amount stays integer" do
      request = %{@request | amount_cents: 12_345, email: nil, name: ""}

      expect(Req, :post, fn _req, opts ->
        assert opts[:json] == %{
                 "products" => ["prod_1"],
                 "amount" => 12_345,
                 "currency" => "usd",
                 "success_url" => "https://app.example/billing/topup/return/topup_1",
                 "metadata" => %{"topup_id" => "topup_1"}
               }

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "co_1", "url" => "https://checkout/co_1"}}}
      end)

      assert {:ok, _handle} = Polar.create_checkout(request, [])
    end

    test "opts override the app-env block (server pinning)" do
      expect(Req, :post, fn req, _opts ->
        assert req.options[:base_url] == "https://api.polar.sh"

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "co_1", "url" => "https://checkout/co_1"}}}
      end)

      assert {:ok, _handle} = Polar.create_checkout(@request, server: "production")
    end

    test "answers :missing_config without a token, product, or known server" do
      Application.put_env(:flux_vale, :polar, server: "sandbox", product_id: "prod_1")
      assert {:error, :missing_config} = Polar.create_checkout(@request, [])

      Application.put_env(:flux_vale, :polar,
        access_token: "sbx_token",
        server: "sandbox"
      )

      assert {:error, :missing_config} = Polar.create_checkout(@request, [])

      Application.put_env(:flux_vale, :polar,
        access_token: "sbx_token",
        product_id: "prod_1",
        server: "staging"
      )

      assert {:error, :missing_config} = Polar.create_checkout(@request, [])
    end

    test "maps non-2xx to :api_error" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "invalid"}}}
      end)

      assert {:error, :api_error} = Polar.create_checkout(@request, [])
    end

    test "maps transport failures to :network_error" do
      expect(Req, :post, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :network_error} = Polar.create_checkout(@request, [])
    end

    test "answers :invalid_response when the body lacks id/url" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "co_1"}}}
      end)

      assert {:error, :invalid_response} = Polar.create_checkout(@request, [])
    end
  end

  describe "verify_webhook/2" do
    test "accepts a Standard Webhooks secret (decoded whsec_ key bytes)" do
      body = ~s({"type":"order.paid"})
      composed = composed(@standard_key, body)

      assert :ok = Polar.verify_webhook(body, composed)
    end

    test "accepts a legacy Polar secret (raw string key bytes)" do
      Application.put_env(:flux_vale, :polar,
        access_token: "sbx_token",
        webhook_secret: @legacy_secret,
        server: "sandbox",
        product_id: "prod_1"
      )

      body = ~s({"type":"order.paid"})
      composed = composed(@legacy_secret, body)

      assert :ok = Polar.verify_webhook(body, composed)
    end

    test "verifies against any entry of a rotated (multi-signature) header" do
      body = ~s({"type":"order.paid"})
      ts = now_ts()
      valid = signature(@standard_key, ts, body)
      # The garbage entry must not shadow the valid one.
      composed = "msg_1." <> ts <> ".v1,deadbeef " <> valid

      assert :ok = Polar.verify_webhook(body, composed)
    end

    test "rejects a wrong secret" do
      body = ~s({"type":"order.paid"})
      composed = composed("wrong_key", body)

      assert {:error, :signature_mismatch} = Polar.verify_webhook(body, composed)
    end

    test "rejects a tampered body" do
      composed = composed(@standard_key, ~s({"type":"order.paid"}))

      assert {:error, :signature_mismatch} =
               Polar.verify_webhook(~s({"type":"order.failed"}), composed)
    end

    test "rejects a stale timestamp (outside the ±5-minute window)" do
      body = ~s({"type":"order.paid"})
      stale = Integer.to_string(System.os_time(:second) - 3600)
      composed = "msg_1." <> stale <> "." <> signature(@standard_key, stale, body)

      assert {:error, :signature_mismatch} = Polar.verify_webhook(body, composed)
    end

    test "rejects a malformed timestamp without raising" do
      body = ~s({"type":"order.paid"})
      ts = "not-a-timestamp"
      composed = "msg_1." <> ts <> "." <> signature(@standard_key, ts, body)

      assert {:error, :signature_mismatch} = Polar.verify_webhook(body, composed)
    end

    test "rejects a signature entry without the v1, prefix" do
      body = ~s({"type":"order.paid"})
      ts = now_ts()
      mac = :crypto.mac(:hmac, :sha256, @standard_key, "msg_1." <> ts <> "." <> body)
      composed = "msg_1." <> ts <> "." <> Base.encode64(mac)

      assert {:error, :signature_mismatch} = Polar.verify_webhook(body, composed)
    end

    test "an undecodable whsec_ secret falls back to the legacy derivation" do
      Application.put_env(:flux_vale, :polar,
        access_token: "sbx_token",
        webhook_secret: "whsec_not!!base64!!",
        server: "sandbox",
        product_id: "prod_1"
      )

      body = ~s({"type":"order.paid"})
      # Keyed by the raw secret string — the only remaining candidate.
      composed = composed("whsec_not!!base64!!", body)

      assert :ok = Polar.verify_webhook(body, composed)
    end

    test "answers :missing_signature for nil, empty, or short compositions" do
      body = ~s({"type":"order.paid"})

      assert {:error, :missing_signature} = Polar.verify_webhook(body, nil)
      assert {:error, :missing_signature} = Polar.verify_webhook(body, "")
      assert {:error, :missing_signature} = Polar.verify_webhook(body, "msg_1")
      assert {:error, :missing_signature} = Polar.verify_webhook(body, "msg_1." <> now_ts())
    end

    test "answers :missing_config without a secret" do
      Application.put_env(:flux_vale, :polar, access_token: "sbx_token")

      assert {:error, :missing_config} =
               Polar.verify_webhook(~s({"type":"order.paid"}), "msg_1." <> now_ts() <> ".v1,AA==")
    end
  end

  describe "fetch_payment/1" do
    test "normalizes a succeeded checkout — the payments row keys the CHECKOUT id" do
      body = %{"id" => "co_1", "status" => "succeeded", "amount" => 10_000}

      expect(Req, :get, fn req, opts ->
        assert req.options[:base_url] == "https://sandbox-api.polar.sh"
        assert Req.Request.get_header(req, "authorization") == ["bearer sbx_token"]
        assert opts[:url] == "/v1/checkouts/co_1"
        {:ok, %Req.Response{status: 200, body: body}}
      end)

      # Contract point 2 (#377): the request-level :completed maps to
      # a :succeeded payment row carrying the checkout id — what
      # ReconcileTopup keys `polar:<checkout_id>` on, identical to
      # the webhook path.
      assert {:ok, payment} = Polar.fetch_payment("co_1")

      assert payment == %{
               payment_request_id: "co_1",
               status: :completed,
               amount_cents: 10_000,
               payments: [%{id: "co_1", status: :succeeded, amount_cents: 10_000}]
             }
    end

    test "non-completed statuses normalize and mirror into the payments row" do
      for {wire, expected} <- [
            {"open", :pending},
            {"confirmed", :pending},
            {"failed", :failed},
            {"expired", :expired},
            {"mysterious", :unknown}
          ] do
        expect(Req, :get, fn _req, _opts ->
          {:ok,
           %Req.Response{status: 200, body: %{"id" => "co_1", "status" => wire, "amount" => 500}}}
        end)

        assert {:ok, %{status: ^expected, payments: [%{status: ^expected}]}} =
                 Polar.fetch_payment("co_1")
      end
    end

    test "answers :invalid_response for malformed bodies" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"status" => "succeeded"}}}
      end)

      assert {:error, :invalid_response} = Polar.fetch_payment("co_1")

      # Polar amounts are integer cents — strings/null never coerce.
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "co_1", "amount" => "500"}}}
      end)

      assert {:error, :invalid_response} = Polar.fetch_payment("co_1")

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "co_1", "amount" => nil}}}
      end)

      assert {:error, :invalid_response} = Polar.fetch_payment("co_1")
    end

    test "answers :missing_config without a token" do
      Application.put_env(:flux_vale, :polar, server: "sandbox", product_id: "prod_1")

      assert {:error, :missing_config} = Polar.fetch_payment("co_1")
    end

    test "maps API and network failures to their atoms" do
      expect(Req, :get, fn _req, _opts -> {:ok, %Req.Response{status: 404, body: %{}}} end)
      assert {:error, :api_error} = Polar.fetch_payment("co_1")

      expect(Req, :get, fn _req, _opts -> {:error, %Req.TransportError{reason: :timeout}} end)
      assert {:error, :network_error} = Polar.fetch_payment("co_1")
    end

    test "percent-encodes a hostile id so it cannot retarget the GET" do
      expect(Req, :get, fn _req, opts ->
        assert opts[:url] == "/v1/checkouts/..%2Fevil%3Fid%3D1"
        {:ok, %Req.Response{status: 200, body: %{"id" => "x", "amount" => 500}}}
      end)

      assert {:ok, _payment} = Polar.fetch_payment("../evil?id=1")
    end
  end

  test "idempotency_key/1 prefixes the checkout id with the provider namespace" do
    assert Polar.idempotency_key("co_1") == "polar:co_1"
  end

  # Standard Webhooks signing over "<id>.<ts>.<body>" with a real
  # HMAC — the same math the adapter runs.
  defp signature(key, ts, body) do
    signed = "msg_1." <> ts <> "." <> body
    mac = :crypto.mac(:hmac, :sha256, key, signed)
    "v1," <> Base.encode64(mac)
  end

  defp composed(key, body) do
    ts = now_ts()
    "msg_1." <> ts <> "." <> signature(key, ts, body)
  end

  defp now_ts do
    seconds = System.os_time(:second)
    Integer.to_string(seconds)
  end
end
