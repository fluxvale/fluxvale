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
  alias FluxVale.Billing.Providers.PolarTest.NoLaneAdopter

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
        assert Req.Request.get_header(req, "authorization") == ["Bearer sbx_token"]
        assert opts[:url] == "/v1/checkouts/"

        assert opts[:json] == %{
                 "products" => ["prod_1"],
                 "amount" => 500,
                 "currency" => "usd",
                 "success_url" =>
                   "https://app.example/billing/topup/return/topup_1?checkout_id={CHECKOUT_ID}",
                 "return_url" => "https://app.example/billing/topup/return/topup_1",
                 "metadata" => %{"topup_id" => "topup_1"},
                 "allow_discount_codes" => false,
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
                 "success_url" =>
                   "https://app.example/billing/topup/return/topup_1?checkout_id={CHECKOUT_ID}",
                 "return_url" => "https://app.example/billing/topup/return/topup_1",
                 "metadata" => %{"topup_id" => "topup_1"},
                 "allow_discount_codes" => false
               }

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "co_1", "url" => "https://checkout/co_1"}}}
      end)

      assert {:ok, _handle} = Polar.create_checkout(request, [])
    end

    # The {CHECKOUT_ID} substitution token (#377): Polar replaces it
    # with the checkout session id at redirect time — the confirmation
    # landing's correlation param. Query-string-safe, never appended
    # twice.
    test "joins the token onto an existing query string with &" do
      request = %{
        @request
        | redirect_url: "https://app.example/billing/topup/return/topup_1?session=x"
      }

      expect(Req, :post, fn _req, opts ->
        assert opts[:json]["success_url"] ==
                 "https://app.example/billing/topup/return/topup_1?session=x&checkout_id={CHECKOUT_ID}"

        assert opts[:json]["return_url"] ==
                 "https://app.example/billing/topup/return/topup_1?session=x"

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "co_1", "url" => "https://checkout/co_1"}}}
      end)

      assert {:ok, _handle} = Polar.create_checkout(request, [])
    end

    test "never double-appends when the caller already carries the token" do
      request = %{
        @request
        | redirect_url: "https://app.example/return?checkout_id={CHECKOUT_ID}"
      }

      expect(Req, :post, fn _req, opts ->
        assert opts[:json]["success_url"] ==
                 "https://app.example/return?checkout_id={CHECKOUT_ID}"

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

    # The discount-code dial (#377, e2e-only): off by default (asserted
    # in the exact-JSON tests above), on when the config or an opts pin
    # says so — a buyer-entered code would pay less while the webhook
    # credits the pre-discount subtotal.
    test "a configured allow_discount_codes sends true" do
      Application.put_env(:flux_vale, :polar,
        access_token: "sbx_token",
        webhook_secret: @standard_secret,
        server: "sandbox",
        product_id: "prod_1",
        allow_discount_codes: true
      )

      expect(Req, :post, fn _req, opts ->
        assert opts[:json]["allow_discount_codes"] == true

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "co_1", "url" => "https://checkout/co_1"}}}
      end)

      assert {:ok, _handle} = Polar.create_checkout(@request, [])
    end

    test "opts override the discount-code dial like any other config key" do
      expect(Req, :post, fn _req, opts ->
        assert opts[:json]["allow_discount_codes"] == true

        {:ok,
         %Req.Response{status: 200, body: %{"id" => "co_1", "url" => "https://checkout/co_1"}}}
      end)

      assert {:ok, _handle} = Polar.create_checkout(@request, allow_discount_codes: true)
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
        assert Req.Request.get_header(req, "authorization") == ["Bearer sbx_token"]
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

  # The staged off-session lane (#829). All Req-stubbed — the org is
  # on Polar's Starter plan and cannot run off-session charges; the
  # first live call is S6's, after the Pro upgrade.
  @org_id "11111111-1111-4111-8111-111111111111"

  @session_request %{
    organization_id: @org_id,
    email: "buyer@example.com",
    name: "Buyer One",
    billing_address: %{country: "US", state: "CA"}
  }

  @draft_request %{amount_cents: 2500, currency: "USD", reference: "topup_9"}

  describe "create_billing_session/2" do
    test "upserts the customer by external_id, then opens the portal session" do
      expect(Req, :post, fn req, opts ->
        assert req.options[:base_url] == "https://sandbox-api.polar.sh"
        assert Req.Request.get_header(req, "authorization") == ["Bearer sbx_token"]
        assert opts[:url] == "/v1/customers/"

        # Exact JSON: external_id carries the org id, the full
        # billing address rides along, no null values are sent.
        assert opts[:json] == %{
                 "external_id" => @org_id,
                 "email" => "buyer@example.com",
                 "name" => "Buyer One",
                 "billing_address" => %{"country" => "US", "state" => "CA"}
               }

        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_1", "external_id" => @org_id}}}
      end)

      expect(Req, :post, fn _req, opts ->
        assert opts[:url] == "/v1/customer-sessions/"
        assert opts[:json] == %{"customer_id" => "cus_1"}

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "ses_1", "customer_portal_url" => "https://polar/portal"}
         }}
      end)

      assert {:ok, %{customer_id: "cus_1", portal_url: "https://polar/portal"}} =
               Polar.create_billing_session(@session_request, [])
    end

    test "omits a blank name and an absent state — Polar 422s nulls" do
      # email is contract-required (the typedoc's Polar
      # individual-customer note); only blank name/state can be
      # absent on the wire.
      request = %{
        @session_request
        | name: "",
          billing_address: %{country: "PH", state: nil}
      }

      expect(Req, :post, fn _req, opts ->
        assert opts[:json] == %{
                 "external_id" => @org_id,
                 "email" => "buyer@example.com",
                 "billing_address" => %{"country" => "PH"}
               }

        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_1"}}}
      end)

      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{status: 200, body: %{"customer_portal_url" => "https://polar/portal"}}}
      end)

      assert {:ok, %{customer_id: "cus_1"}} = Polar.create_billing_session(request, [])
    end

    test "a 422 upsert with a matching stored address adopts the customer without a patch" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "external_id already exists"}}}
      end)

      expect(Req, :get, fn _req, opts ->
        assert opts[:url] == "/v1/customers/external/#{@org_id}"

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "id" => "cus_9",
             "external_id" => @org_id,
             "billing_address" => %{"country" => "US", "state" => "CA"}
           }
         }}
      end)

      stub(Req, :patch, fn _req, _opts ->
        flunk("a matching address must not patch")
      end)

      expect(Req, :post, fn _req, opts ->
        assert opts[:json] == %{"customer_id" => "cus_9"}

        {:ok,
         %Req.Response{status: 200, body: %{"customer_portal_url" => "https://polar/portal"}}}
      end)

      assert {:ok, %{customer_id: "cus_9"}} = Polar.create_billing_session(@session_request, [])
    end

    test "a stored country differing only in case does not patch" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "id" => "cus_9",
             "external_id" => @org_id,
             "billing_address" => %{"country" => "us", "state" => "CA"}
           }
         }}
      end)

      stub(Req, :patch, fn _req, _opts ->
        flunk("a case-folded country match must not patch")
      end)

      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{status: 200, body: %{"customer_portal_url" => "https://polar/portal"}}}
      end)

      assert {:ok, %{customer_id: "cus_9"}} = Polar.create_billing_session(@session_request, [])
    end

    test "a 422 upsert with no stored address patches, then opens the session" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "cus_9", "external_id" => @org_id}
         }}
      end)

      expect(Req, :patch, fn _req, opts ->
        assert opts[:url] == "/v1/customers/cus_9"

        assert opts[:json] == %{
                 "external_id" => @org_id,
                 "email" => "buyer@example.com",
                 "name" => "Buyer One",
                 "billing_address" => %{"country" => "US", "state" => "CA"}
               }

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "cus_9", "billing_address" => %{"country" => "US", "state" => "CA"}}
         }}
      end)

      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{status: 200, body: %{"customer_portal_url" => "https://polar/portal"}}}
      end)

      assert {:ok, %{customer_id: "cus_9"}} = Polar.create_billing_session(@session_request, [])
    end

    test "a garbage stored country differs and the patch fixes it" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "id" => "cus_9",
             "external_id" => @org_id,
             "billing_address" => %{"country" => 840}
           }
         }}
      end)

      expect(Req, :patch, fn _req, opts ->
        assert opts[:url] == "/v1/customers/cus_9"
        assert opts[:json]["billing_address"] == %{"country" => "US", "state" => "CA"}

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "cus_9", "billing_address" => %{"country" => "US", "state" => "CA"}}
         }}
      end)

      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{status: 200, body: %{"customer_portal_url" => "https://polar/portal"}}}
      end)

      assert {:ok, %{customer_id: "cus_9"}} = Polar.create_billing_session(@session_request, [])
    end

    test "a 401 upsert short-circuits to :api_error without a lookup" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 401, body: %{"detail" => "bad token"}}}
      end)

      stub(Req, :get, fn _req, _opts ->
        flunk("a 401 upsert cannot mean the external_id exists")
      end)

      assert {:error, :api_error} = Polar.create_billing_session(@session_request, [])
    end

    test "an absent customer (404 on the lookup) answers :api_error" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, opts ->
        assert opts[:url] == "/v1/customers/external/#{@org_id}"
        {:ok, %Req.Response{status: 404, body: %{"detail" => "not found"}}}
      end)

      assert {:error, :api_error} = Polar.create_billing_session(@session_request, [])
    end

    test "a failed customer lookup answers :api_error" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 500, body: %{"detail" => "boom"}}}
      end)

      assert {:error, :api_error} = Polar.create_billing_session(@session_request, [])
    end

    test "a matched customer without a usable id is malformed gateway data" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"external_id" => @org_id}}}
      end)

      assert {:error, :invalid_response} = Polar.create_billing_session(@session_request, [])
    end

    test "a failed patch answers :api_error" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_9", "external_id" => @org_id}}}
      end)

      expect(Req, :patch, fn _req, _opts ->
        {:ok, %Req.Response{status: 500, body: %{"detail" => "boom"}}}
      end)

      assert {:error, :api_error} = Polar.create_billing_session(@session_request, [])
    end

    test "transport failures on each leg answer :network_error" do
      expect(Req, :post, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :network_error} = Polar.create_billing_session(@session_request, [])

      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error} = Polar.create_billing_session(@session_request, [])

      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_9", "external_id" => @org_id}}}
      end)

      expect(Req, :patch, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error} = Polar.create_billing_session(@session_request, [])

      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 422, body: %{"detail" => "conflict"}}}
      end)

      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_9", "external_id" => @org_id}}}
      end)

      expect(Req, :patch, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_9"}}}
      end)

      expect(Req, :post, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :network_error} = Polar.create_billing_session(@session_request, [])
    end

    test "answers :invalid_response when the upsert body lacks an id" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"external_id" => @org_id}}}
      end)

      assert {:error, :invalid_response} = Polar.create_billing_session(@session_request, [])
    end

    test "answers :invalid_response when the session body lacks the portal URL" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_1"}}}
      end)

      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "ses_1"}}}
      end)

      assert {:error, :invalid_response} = Polar.create_billing_session(@session_request, [])
    end

    test "maps session API and network failures to their atoms" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_1"}}}
      end)

      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 403, body: %{"detail" => "forbidden"}}}
      end)

      assert {:error, :api_error} = Polar.create_billing_session(@session_request, [])

      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "cus_1"}}}
      end)

      expect(Req, :post, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error} = Polar.create_billing_session(@session_request, [])
    end

    test "answers :missing_config without a token" do
      Application.put_env(:flux_vale, :polar, server: "sandbox")

      assert {:error, :missing_config} = Polar.create_billing_session(@session_request, [])
    end
  end

  describe "list_payment_methods/1" do
    test "counts the methods and names the default from an items response" do
      expect(Req, :get, fn _req, opts ->
        assert opts[:url] == "/v1/customers/cus_1/payment-methods"

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "items" => [
               %{"id" => "pm_2", "is_default" => false},
               %{"id" => "pm_1", "is_default" => true}
             ]
           }
         }}
      end)

      assert {:ok, 2, "pm_1"} = Polar.list_payment_methods("cus_1")
    end

    test "empty items answer {0, nil}" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"items" => []}}}
      end)

      assert {:ok, 0, nil} = Polar.list_payment_methods("cus_1")
    end

    test "no default among the items answers nil for the ref" do
      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"items" => [%{"id" => "pm_2", "is_default" => false}]}
         }}
      end)

      assert {:ok, 1, nil} = Polar.list_payment_methods("cus_1")
    end

    test "a default method without an id degrades to a nil ref" do
      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"items" => [%{"is_default" => true}]}
         }}
      end)

      assert {:ok, 1, nil} = Polar.list_payment_methods("cus_1")
    end

    test "reads a bare-array list shape too" do
      expect(Req, :get, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: [%{"id" => "pm_1", "is_default" => true}]
         }}
      end)

      assert {:ok, 1, "pm_1"} = Polar.list_payment_methods("cus_1")
    end

    test "maps API and network failures to their atoms" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 500, body: %{"detail" => "boom"}}}
      end)

      assert {:error, :api_error} = Polar.list_payment_methods("cus_1")

      expect(Req, :get, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error} = Polar.list_payment_methods("cus_1")
    end

    test "answers :invalid_response for a body that is neither items-wrapped nor an array" do
      expect(Req, :get, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"error" => "junk"}}}
      end)

      assert {:error, :invalid_response} = Polar.list_payment_methods("cus_1")
    end

    test "answers :missing_config without a token" do
      Application.put_env(:flux_vale, :polar, server: "sandbox")

      assert {:error, :missing_config} = Polar.list_payment_methods("cus_1")
    end
  end

  describe "create_draft_charge/2" do
    test "posts the draft order and returns the handle" do
      expect(Req, :post, fn _req, opts ->
        assert opts[:url] == "/v1/orders/"

        # Exact JSON — the map equality proves OrderCreate's SINGULAR
        # product_id (the checkout body's `products` array is another
        # endpoint's shape), no success_url/return_url on a draft
        # (there is no hosted flow), and the amount stays an integer.
        assert opts[:json] == %{
                 "customer_id" => "cus_1",
                 "product_id" => "prod_1",
                 "amount" => 2500,
                 "metadata" => %{"topup_id" => "topup_9"}
               }

        # Order responses carry no top-level `amount` — the money
        # rides subtotal_amount (contract point 1).
        {:ok, %Req.Response{status: 200, body: %{"id" => "ord_1", "subtotal_amount" => 2500}}}
      end)

      assert {:ok, %{order_id: "ord_1", amount_cents: 2500}} =
               Polar.create_draft_charge(@draft_request, customer_id: "cus_1")
    end

    test "answers :missing_config without opts[:customer_id] and never posts" do
      stub(Req, :post, fn _req, _opts ->
        flunk("no draft without a customer id")
      end)

      assert {:error, :missing_config} = Polar.create_draft_charge(@draft_request, [])
    end

    test "answers :invalid_response when the body lacks an id" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"subtotal_amount" => 2500}}}
      end)

      assert {:error, :invalid_response} =
               Polar.create_draft_charge(@draft_request, customer_id: "cus_1")
    end

    test "answers :invalid_response for a non-integer amount" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"id" => "ord_1", "subtotal_amount" => "2500"}}}
      end)

      assert {:error, :invalid_response} =
               Polar.create_draft_charge(@draft_request, customer_id: "cus_1")
    end

    test "maps API and network failures to their atoms" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 403, body: %{"detail" => "off-session not enabled"}}}
      end)

      assert {:error, :api_error} =
               Polar.create_draft_charge(@draft_request, customer_id: "cus_1")

      expect(Req, :post, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :network_error} =
               Polar.create_draft_charge(@draft_request, customer_id: "cus_1")
    end
  end

  describe "finalize_charge/2" do
    test "a paid finalize answers :completed with the echoed amount" do
      expect(Req, :post, fn _req, opts ->
        assert opts[:url] == "/v1/orders/ord_1/finalize"
        assert opts[:json] == %{}

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "ord_1", "status" => "paid", "subtotal_amount" => 2500}
         }}
      end)

      assert {:ok,
              %{order_id: "ord_1", amount_cents: 2500, status: :completed, failure_reason: nil}} =
               Polar.finalize_charge("ord_1", [])
    end

    test "a 402 decline is an ANSWERED failure, not an error" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 402, body: %{"detail" => "no payment method"}}}
      end)

      assert {:ok,
              %{
                order_id: "ord_1",
                amount_cents: nil,
                status: :failed,
                failure_reason: "http_402: no payment method"
              }} = Polar.finalize_charge("ord_1", [])
    end

    test "a failed finalize that echoes the amount carries it" do
      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 402,
           body: %{"detail" => "SCA required", "subtotal_amount" => 2500}
         }}
      end)

      assert {:ok, %{amount_cents: 2500, failure_reason: "http_402: SCA required"}} =
               Polar.finalize_charge("ord_1", [])
    end

    test "a 403 (off-session not enabled) answers :failed with the bare code" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 403, body: %{"error" => %{"nested" => true}}}}
      end)

      assert {:ok, %{status: :failed, failure_reason: "http_403"}} =
               Polar.finalize_charge("ord_1", [])
    end

    test "a 412 (not draft) answers :failed" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 412, body: %{}}}
      end)

      assert {:ok, %{status: :failed, failure_reason: "http_412"}} =
               Polar.finalize_charge("ord_1", [])
    end

    test "other non-2xx are unknown outcomes — :api_error" do
      expect(Req, :post, fn _req, _opts ->
        {:ok, %Req.Response{status: 500, body: %{"detail" => "boom"}}}
      end)

      assert {:error, :api_error} = Polar.finalize_charge("ord_1", [])
    end

    test "transport failures are unknown outcomes — :network_error" do
      expect(Req, :post, fn _req, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error} = Polar.finalize_charge("ord_1", [])
    end

    test "a 2xx that is not paid is malformed gateway data" do
      expect(Req, :post, fn _req, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"id" => "ord_1", "status" => "draft", "subtotal_amount" => 2500}
         }}
      end)

      assert {:error, :invalid_response} = Polar.finalize_charge("ord_1", [])
    end

    test "answers :missing_config without a token" do
      Application.put_env(:flux_vale, :polar, server: "sandbox")

      assert {:error, :missing_config} = Polar.finalize_charge("ord_1", [])
    end
  end

  describe "behaviour defaults (the use-injected off-session lane)" do
    test "an adopter that defines none of the four answers :unsupported" do
      assert {:error, :unsupported} = NoLaneAdopter.create_billing_session(%{}, [])
      assert {:error, :unsupported} = NoLaneAdopter.list_payment_methods("cus_1")

      assert {:error, :unsupported} =
               NoLaneAdopter.create_draft_charge(%{amount_cents: 2500}, customer_id: "cus_1")

      assert {:error, :unsupported} = NoLaneAdopter.finalize_charge("ord_1", [])
    end
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

# Pins the default-clause contract (docs/plans/829 #S1): an adopter
# that only `use`s the behaviour answers {:error, :unsupported} for
# the four staged callbacks. The original three have no defaults —
# every adopter implements them — so they are stubbed (specs and all)
# purely to keep this module's compile quiet.
defmodule FluxVale.Billing.Providers.PolarTest.NoLaneAdopter do
  use FluxVale.Billing.PaymentProvider

  alias FluxVale.Billing.PaymentProvider

  @spec create_checkout(PaymentProvider.checkout_request(), keyword()) ::
          {:ok, PaymentProvider.checkout()} | {:error, PaymentProvider.error()}
  def create_checkout(_request, _opts), do: {:error, :missing_config}

  @spec verify_webhook(binary(), String.t() | nil) ::
          :ok | {:error, :missing_signature | :missing_config | :signature_mismatch}
  def verify_webhook(_raw_body, _signature), do: {:error, :missing_signature}

  @spec fetch_payment(String.t()) ::
          {:ok, PaymentProvider.payment()} | {:error, PaymentProvider.error()}
  def fetch_payment(_payment_request_id), do: {:error, :missing_config}
end
