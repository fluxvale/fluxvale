defmodule FluxVale.Billing.Providers.Polar do
  @moduledoc """
  Polar gateway (#377, ADR-0029's second provider) — hosted
  custom-price checkouts over the Checkout Sessions API, Standard
  Webhooks event deliveries.

  Sandbox first (the org token is minted per Polar environment):
  `server` defaults to "sandbox"; production flips via `POLAR_SERVER`
  at the gated cutover (#377 S4). Config block `config :flux_vale,
  :polar` — `access_token`, `webhook_secret`, `server`, `product_id`
  — resolved from env by runtime.exs (1Password-sourced env in the
  cluster, ADR-0021 Am. 3), never committed.

  ## Webhook signature

  Standard Webhooks: three headers (`webhook-id`,
  `webhook-timestamp`, `webhook-signature`), HMAC-SHA256 over
  `"<id>.<timestamp>.<body>"`, signatures `v1,<base64>`
  (space-separated entries when rotated). The behaviour takes one
  binary, so the controller passes the three header values
  dot-joined in signed order (uuids, unix timestamps, and base64
  are dot-free — the join is unambiguous). A timestamp outside the
  ±5-minute window mismatches — unlike HitPay, the scheme carries
  its own replay defense, and the ledger's `polar:<checkout_id>`
  idempotency stays the second lock (contract point 2, #377).

  Secrets minted after 2026-09-08 are Standard Webhooks
  (`whsec_<base64>` — key = the decoded bytes); older ones are
  Polar's legacy HMAC (key = the raw secret bytes). Both are tried —
  the dashboard doesn't mark which kind a secret is.

  ## Wire format notes

  JSON bodies, Bearer auth (the org token scopes to the
  organization: `organization_id` is never sent — Polar 422s it on
  org-scoped tokens). `amount` is integer cents applying to the
  product's custom (pay-what-you-want) price — the "FluxVale
  Credits" product prices tax-inclusive, so the buyer pays exactly
  our gross and the webhook maps `subtotal_amount` (never
  `total_amount`) back to it — contract point 1 (#377). Checkout
  `metadata` rides to the resulting order (`topup_id`). The checkout
  session id is the payment identity everywhere —
  `payment_request_id`, `payment_id`, and `"polar:" <> checkout_id`
  — so the webhook and reconcile paths converge on one idempotency
  key (contract point 2, #377).

  ## Off-session charges (staged, #829)

  The auto-recharge lane splits into a draft order (`POST /v1/orders/`)
  and a synchronous charge (`POST /v1/orders/{id}/finalize`). Draft
  creation NEVER charges — the order id comes back before any charge
  trigger and is what the caller persists; on Polar the order id is
  the payment identity (`payment_request_id`/`payment_id` both carry
  it, like the checkout session id above). A finalize that answers
  402/403/412 is an ANSWERED failure — decline/no-method/SCA,
  off-session not enabled, not draft — mapped to `status: :failed`,
  never an error tuple; the draft stays re-finalizable on Polar's side
  and this adapter never re-drives it. Reading a lane row back
  (`GET /v1/orders/{id}`, `fetch_order/1`) is the stale-pending
  reconciliation's fetch — `fetch_payment/1` reads the CHECKOUT
  endpoint, where an order id 404s; a 404 here answers :api_error like
  any gateway fault, and the sweep's reconciliation leaves the row
  pending on it (never failing a possibly-charged row on an answer it
  cannot trust). NO live call exists in this
  lane yet: the org is on Polar's Starter plan, which cannot run
  off-session charges — activation (the Pro upgrade, plan #829 S6) is
  when the first real request fires. Everything here is
  Req-stubbed-tested.

  ## Customer upsert (the billing-session choice)

  `POST /v1/customers/` is not an upsert — an existing `external_id`
  422s. So `create_billing_session/2` posts the create first and falls
  through to the lookup only on that conflict class (404/422): the
  documented exact-match read `GET /v1/customers/external/{external_id}`
  (the list endpoint carries no external_id filter and paginates),
  adopting the customer and PATCHing it only when its stored
  country/state differs from the caller's evidence (Polar taxes drafts
  from the stored address, so the evidence is authoritative; the
  compare is nil-safe and case-folds the country so a stored "us"
  cannot patch every session). Any other create failure
  (401/403/429/5xx) cannot mean "exists" and short-circuits to
  :api_error — no duplicate request against a 429. Line-level address
  fields and the method itself are the buyer's — set in the portal,
  never here.
  """

  use FluxVale.Billing.PaymentProvider

  alias FluxVale.Billing.PaymentProvider

  require Logger

  @config_key :polar

  # Polar's literal substitution token for success_url — the checkout
  # session id replaces it at redirect time (their docs), giving the
  # return landing its correlation param (#377).
  @checkout_id_token "checkout_id={CHECKOUT_ID}"

  # Polar's OpenAPI servers block — the only two URLs, never an
  # invented one.
  @base_urls %{
    "sandbox" => "https://sandbox-api.polar.sh",
    "production" => "https://api.polar.sh"
  }

  # Checkout-session statuses ("open"/"confirmed"/…) normalized to
  # the behaviour's vocabulary; payment-row status is derived below.
  @status_map %{
    "open" => :pending,
    "confirmed" => :pending,
    "succeeded" => :completed,
    "failed" => :failed,
    "expired" => :expired
  }

  @timestamp_tolerance_seconds 300

  # Order statuses (the off-session lane's fetch, #829 S4): the stale
  # reconciliation keys on :paid (charged) vs :draft (never finalized —
  # nothing can charge); any other Polar status normalizes to :unknown.
  @order_status_map %{"paid" => :paid, "draft" => :draft}

  @impl PaymentProvider
  @spec create_checkout(PaymentProvider.checkout_request(), keyword()) ::
          {:ok, PaymentProvider.checkout()} | {:error, PaymentProvider.error()}
  def create_checkout(request, opts) do
    config = Keyword.merge(env_config(), opts)

    with {:ok, req} <- client(config),
         {:ok, product_id} <- fetch_config(config, :product_id) do
      req
      |> Req.post(url: "/v1/checkouts/", json: checkout_body(request, product_id, config))
      |> handle_checkout_response()
    end
  end

  @impl PaymentProvider
  @spec verify_webhook(binary(), String.t() | nil) ::
          :ok | {:error, :missing_signature | :missing_config | :signature_mismatch}
  def verify_webhook(raw_body, composed) when is_binary(raw_body) do
    with {:ok, [id, ts, sigs]} <- split_composed(composed),
         {:ok, secret} <- fetch_config(env_config(), :webhook_secret),
         :ok <- check_timestamp(ts) do
      signed = id <> "." <> ts <> "." <> raw_body
      candidates = key_candidates(secret)

      if Enum.any?(candidates, &signature_match?(&1, sigs, signed)) do
        :ok
      else
        {:error, :signature_mismatch}
      end
    end
  end

  @impl PaymentProvider
  @spec fetch_payment(String.t()) ::
          {:ok, PaymentProvider.payment()} | {:error, PaymentProvider.error()}
  def fetch_payment(checkout_id) when is_binary(checkout_id) do
    with {:ok, req} <- client(env_config()) do
      # Percent-encode: an id carrying ../, ?, or # (a hostile or
      # malformed webhook) must not retarget the GET. Item paths
      # take no trailing slash (collections do — the swap 307s in
      # both directions).
      encoded = URI.encode(checkout_id, &URI.char_unreserved?/1)

      req
      |> Req.get(url: "/v1/checkouts/#{encoded}")
      |> handle_payment_response()
    end
  end

  @impl PaymentProvider
  @spec create_billing_session(PaymentProvider.billing_session_request(), keyword()) ::
          {:ok, PaymentProvider.billing_session()} | {:error, PaymentProvider.error()}
  def create_billing_session(request, opts) do
    config = Keyword.merge(env_config(), opts)

    with {:ok, req} <- client(config),
         {:ok, customer_id} <- upsert_customer(req, request) do
      result = Req.post(req, url: "/v1/customer-sessions/", json: %{"customer_id" => customer_id})
      session_outcome(result, customer_id)
    end
  end

  @impl PaymentProvider
  @spec list_payment_methods(String.t()) ::
          {:ok, non_neg_integer(), String.t() | nil} | {:error, PaymentProvider.error()}
  def list_payment_methods(provider_customer_id) when is_binary(provider_customer_id) do
    with {:ok, req} <- client(env_config()) do
      encoded = URI.encode(provider_customer_id, &URI.char_unreserved?/1)

      req
      |> Req.get(url: "/v1/customers/#{encoded}/payment-methods")
      |> handle_methods_response()
    end
  end

  @doc """
  A DRAFT order for the gross — creation charges nothing (#829). The
  order id it returns is what the caller persists before any charge
  trigger; the charge happens at `finalize_charge/2`. No success_url/
  return_url: there is no hosted flow to return from. Currency rides
  the product (the request's `currency` documents the caller's unit);
  `amount` is integer gross cents, the same wire unit as
  `create_checkout/2`. The response's money reads `subtotal_amount` —
  orders carry no top-level `amount`.
  """
  @impl PaymentProvider
  @spec create_draft_charge(PaymentProvider.draft_charge_request(), keyword()) ::
          {:ok, PaymentProvider.draft_charge()} | {:error, PaymentProvider.error()}
  def create_draft_charge(request, opts) do
    config = Keyword.merge(env_config(), opts)

    with {:ok, req} <- client(config),
         {:ok, product_id} <- fetch_config(config, :product_id),
         {:ok, customer_id} <- fetch_config(opts, :customer_id) do
      req
      |> Req.post(url: "/v1/orders/", json: draft_body(request, product_id, customer_id))
      |> handle_draft_response()
    end
  end

  @doc """
  The synchronous charge attempt on a draft order (#829). An answered
  decline (402/403/412) is `{:ok, …, status: :failed}` — never an
  error tuple; only unknown outcomes (transport, other non-2xx) are.
  """
  @impl PaymentProvider
  @spec finalize_charge(String.t(), keyword()) ::
          {:ok, PaymentProvider.charge_outcome()} | {:error, PaymentProvider.error()}
  def finalize_charge(order_id, opts) when is_binary(order_id) do
    with {:ok, req} <- client(Keyword.merge(env_config(), opts)) do
      encoded = URI.encode(order_id, &URI.char_unreserved?/1)

      req
      |> Req.post(url: "/v1/orders/#{encoded}/finalize", json: %{})
      |> handle_finalize_response(order_id)
    end
  end

  @doc """
  The ledger idempotency key for a Polar payment (ADR-0029: the
  provider-prefixed payment id — here the checkout session id,
  contract point 2, #377).
  """
  @spec idempotency_key(String.t()) :: String.t()
  def idempotency_key(checkout_id) when is_binary(checkout_id), do: "polar:" <> checkout_id

  @doc """
  Reads an ORDER back (the off-session lane's persisted id, #829 S4) —
  `GET /v1/orders/{id}`. `fetch_payment/1` cannot serve this lane: it
  reads the checkout endpoint, where an order id 404s. A 404 is logged
  and answers :api_error like any gateway fault (see the moduledoc);
  transport failures answer :network_error.
  """
  @impl PaymentProvider
  @spec fetch_order(String.t()) ::
          {:ok, PaymentProvider.order()} | {:error, PaymentProvider.error()}
  def fetch_order(order_id) when is_binary(order_id) do
    with {:ok, req} <- client(env_config()) do
      encoded = URI.encode(order_id, &URI.char_unreserved?/1)

      req
      |> Req.get(url: "/v1/orders/#{encoded}")
      |> handle_order_response()
    end
  end

  defp checkout_body(request, product_id, config) do
    base = %{
      "products" => [product_id],
      "amount" => request.amount_cents,
      "currency" => String.downcase(request.currency),
      "success_url" => with_checkout_token(request.redirect_url),
      # The checkout page's back button (abandoned purchase). Sent
      # BARE: Polar documents {CHECKOUT_ID} substitution for
      # success_url only (checked 2026-11-04, api 2026-10) — the
      # return lands on the wizard as today, never mis-correlated
      # (#377).
      "return_url" => request.redirect_url,
      "metadata" => %{"topup_id" => request.reference},
      # #377: buyer-entered codes off by default — the webhook
      # credits the pre-discount subtotal, so a buyer-entered code
      # would pay less while the credit lands full gross
      # (pay-less-credit-full). The e2e-only dial enables it.
      "allow_discount_codes" => Keyword.get(config, :allow_discount_codes, false)
    }

    Map.merge(base, buyer_fields(request))
  end

  # Polar substitutes the literal {CHECKOUT_ID} token into
  # success_url at redirect time (their documented behavior) — the
  # substituted checkout session id is what the confirmation landing
  # correlates on (#377). Query-string-safe either way; a caller
  # already carrying the token is never double-appended.
  defp with_checkout_token(url) do
    if String.contains?(url, @checkout_id_token) do
      url
    else
      separator = if String.contains?(url, "?"), do: "&", else: "?"
      url <> separator <> @checkout_id_token
    end
  end

  # Polar 422s null buyer fields — only populated binaries are sent.
  defp buyer_fields(request) do
    [{"customer_email", request[:email]}, {"customer_name", request[:name]}]
    |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
    |> Map.new()
  end

  # The controller's dot-joined headers, split back into signed
  # order; anything shorter than three parts never reached us as a
  # Standard Webhooks delivery.
  defp split_composed(composed) when is_binary(composed) do
    case String.split(composed, ".", parts: 3) do
      [id, ts, sigs] -> {:ok, [id, ts, sigs]}
      _short -> {:error, :missing_signature}
    end
  end

  defp split_composed(_missing), do: {:error, :missing_signature}

  # The replay window: a timestamp too far from now mismatches, and
  # garbage never crashes the verifier — reconciliation must answer,
  # not raise, on hostile deliveries.
  defp check_timestamp(ts) do
    case Integer.parse(ts) do
      {seconds, ""} ->
        drift = abs(System.os_time(:second) - seconds)

        if drift > @timestamp_tolerance_seconds do
          {:error, :signature_mismatch}
        else
          :ok
        end

      _malformed ->
        {:error, :signature_mismatch}
    end
  end

  # Two key derivations, both accepted: Standard Webhooks secrets
  # key the MAC with the decoded bytes, legacy Polar secrets with
  # the raw string. An undecodable whsec_ secret falls back to the
  # legacy derivation — a mangled config degrades to mismatch, not
  # a crash.
  defp key_candidates("whsec_" <> encoded = secret) do
    case Base.decode64(encoded) do
      {:ok, standard_key} -> [standard_key, secret]
      :error -> [secret]
    end
  end

  defp key_candidates(secret), do: [secret]

  # The header may carry multiple space-separated `v1,<base64>`
  # entries (secret rotation) — any one matching passes, each
  # compare constant-time.
  defp signature_match?(key, sigs, signed) do
    expected =
      :hmac
      |> :crypto.mac(:sha256, key, signed)
      |> Base.encode64()

    sigs
    |> String.split(" ")
    |> Enum.any?(fn
      "v1," <> provided -> Plug.Crypto.secure_compare(provided, expected)
      _unparseable -> false
    end)
  end

  defp base_url(config) do
    with {:ok, server} <- fetch_config(config, :server) do
      case Map.fetch(@base_urls, server) do
        {:ok, base_url} -> {:ok, base_url}
        :error -> {:error, :missing_config}
      end
    end
  end

  # One client per call — the org token's base URL and Bearer header.
  defp client(config) do
    with {:ok, access_token} <- fetch_config(config, :access_token),
         {:ok, base_url} <- base_url(config) do
      req = Req.new(base_url: base_url, headers: [{"authorization", "Bearer " <> access_token}])
      {:ok, req}
    end
  end

  defp env_config do
    Application.get_env(:flux_vale, @config_key, [])
  end

  defp fetch_config(config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :missing_config}
    end
  end

  defp handle_checkout_response(result) do
    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        checkout_from_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Polar checkout API returned #{status}: #{inspect(body)}")
        {:error, :api_error}

      {:error, exception} ->
        Logger.warning("Polar checkout API network error: #{inspect(exception)}")
        {:error, :network_error}
    end
  end

  defp checkout_from_body(%{"id" => id, "url" => url}) when is_binary(id) and is_binary(url) do
    {:ok, %{payment_request_id: id, checkout_url: url}}
  end

  defp checkout_from_body(body) do
    Logger.error("Polar checkout response missing id/url: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp handle_payment_response(result) do
    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        payment_from_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Polar payment API returned #{status}: #{inspect(body)}")
        {:error, :api_error}

      {:error, exception} ->
        Logger.warning("Polar payment API network error: #{inspect(exception)}")
        {:error, :network_error}
    end
  end

  defp payment_from_body(%{"id" => id} = body) when is_binary(id) do
    status = status(body["status"])

    with {:ok, amount_cents} <- parse_amount(body["amount"]) do
      {:ok,
       %{
         payment_request_id: id,
         status: status,
         amount_cents: amount_cents,
         payments: [%{id: id, status: payment_row_status(status), amount_cents: amount_cents}]
       }}
    end
  end

  defp payment_from_body(body) do
    Logger.error("Polar payment response missing id: #{inspect(body)}")
    {:error, :invalid_response}
  end

  # Contract point 2 (#377): the payments row is keyed by the
  # CHECKOUT id — ReconcileTopup looks for %{id, status: :succeeded}
  # exactly like the webhook path, so both converge on
  # `polar:<checkout_id>`. A completed request is the only shape
  # that carries a :succeeded row.
  defp payment_row_status(:completed), do: :succeeded

  defp payment_row_status(other), do: other

  defp status(value) do
    Map.get(@status_map, value, :unknown)
  end

  # Polar amounts are integer cents on the wire — a string, null, or
  # float is malformed gateway data, never a value to coerce.
  defp parse_amount(amount) when is_integer(amount), do: {:ok, amount}

  defp parse_amount(_malformed), do: {:error, :invalid_response}

  # --- Off-session lane (#829): session, methods, draft, finalize ---

  # Polar 422s nulls — only populated string values are sent, the
  # buyer_fields discipline with the customer keys.
  defp customer_body(request) do
    identity = identity_fields(request[:email], request[:name])

    Map.merge(
      %{
        "external_id" => request.organization_id,
        "billing_address" => address_fields(request.billing_address)
      },
      identity
    )
  end

  defp identity_fields(email, name) do
    [{"email", email}, {"name", name}]
    |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
    |> Map.new()
  end

  defp address_fields(billing_address) do
    case billing_address[:state] do
      state when is_binary(state) and state != "" ->
        %{"country" => billing_address.country, "state" => state}

      _blank ->
        %{"country" => billing_address.country}
    end
  end

  # POST /v1/customers/ is not an upsert (an existing external_id
  # 422s) — on the conflict class (404/422), read the existing
  # customer and PATCH it only when the stored address differs
  # ("Customer upsert" in the moduledoc).
  defp upsert_customer(req, request) do
    result = Req.post(req, url: "/v1/customers/", json: customer_body(request))
    upsert_outcome(result, req, request)
  end

  defp upsert_outcome({:ok, %Req.Response{status: status, body: body}}, _req, _request)
       when status in 200..299 do
    customer_id(body)
  end

  # Only an external-id conflict (422) or absence (404) can mean
  # "read the existing customer" — a 401/403/429/5xx deterministically
  # cannot, and a lookup retry on a 429 would double the request rate.
  defp upsert_outcome({:ok, %Req.Response{status: status, body: body}}, req, request)
       when status in [404, 422] do
    Logger.warning("Polar customer upsert returned #{status}: #{inspect(body)}")
    adopt_existing_customer(req, request)
  end

  defp upsert_outcome({:ok, %Req.Response{status: status, body: body}}, _req, _request) do
    Logger.warning("Polar customer upsert returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp upsert_outcome({:error, exception}, _req, _request) do
    Logger.warning("Polar customer upsert network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp adopt_existing_customer(req, request) do
    # The documented exact-match read (the list endpoint carries no
    # external_id filter and paginates) — an id hostile to the path
    # is percent-encoded like every other item path.
    encoded = URI.encode(request.organization_id, &URI.char_unreserved?/1)
    result = Req.get(req, url: "/v1/customers/external/#{encoded}")
    existing_outcome(result, req, request)
  end

  defp existing_outcome({:ok, %Req.Response{status: status, body: body}}, req, request)
       when status in 200..299 do
    adopt_customer(req, request, body)
  end

  # 404 is the honest "absent"; 422 and every other non-2xx is a
  # gateway fault on the lookup leg — both answer :api_error.
  defp existing_outcome({:ok, %Req.Response{status: status, body: body}}, _req, _request) do
    Logger.warning("Polar customer lookup returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp existing_outcome({:error, exception}, _req, _request) do
    Logger.warning("Polar customer lookup network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp adopt_customer(req, request, %{"id" => id} = customer) when is_binary(id) do
    if address_differs?(customer, request) do
      patch_customer(req, request, id)
    else
      {:ok, id}
    end
  end

  defp adopt_customer(_req, _request, _malformed) do
    Logger.error("Polar customer lookup returned a customer without an id")
    {:error, :invalid_response}
  end

  # Only country/state are ours to manage — Polar taxes the draft
  # order from the stored address, so a differing stored value is
  # patched to the caller's evidence. Country compares
  # case-insensitively; state stays exact.
  defp address_differs?(customer, request) do
    stored = customer["billing_address"] || %{}

    stored_country = upcase_country(Map.get(stored, "country"))
    desired_country = upcase_country(request.billing_address[:country])

    stored_country != desired_country or
      Map.get(stored, "state") != request.billing_address[:state]
  end

  # A nil-safe, case-folded compare: a stored "us" against a desired
  # "US" must not patch every session; a garbage non-binary stored
  # value differs, and the patch overwrites it.
  defp upcase_country(nil), do: nil
  defp upcase_country(country) when is_binary(country), do: String.upcase(country)
  defp upcase_country(other), do: other

  defp patch_customer(req, request, id) do
    encoded = URI.encode(id, &URI.char_unreserved?/1)
    result = Req.patch(req, url: "/v1/customers/#{encoded}", json: customer_body(request))
    patch_outcome(result, id)
  end

  defp patch_outcome({:ok, %Req.Response{status: status, body: body}}, _id)
       when status in 200..299 do
    customer_id(body)
  end

  defp patch_outcome({:ok, %Req.Response{status: status, body: body}}, _id) do
    Logger.warning("Polar customer patch returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp patch_outcome({:error, exception}, _id) do
    Logger.warning("Polar customer patch network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp customer_id(%{"id" => id}) when is_binary(id), do: {:ok, id}

  defp customer_id(body) do
    Logger.error("Polar customer response missing id: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp session_outcome({:ok, %Req.Response{status: status, body: body}}, customer_id)
       when status in 200..299 do
    session_from_body(body, customer_id)
  end

  defp session_outcome({:ok, %Req.Response{status: status, body: body}}, _customer_id) do
    Logger.warning("Polar customer-session API returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp session_outcome({:error, exception}, _customer_id) do
    Logger.warning("Polar customer-session API network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp session_from_body(%{"customer_portal_url" => url}, customer_id) when is_binary(url) do
    {:ok, %{customer_id: customer_id, portal_url: url}}
  end

  defp session_from_body(body, _customer_id) do
    Logger.error("Polar customer-session response missing customer_portal_url: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp handle_methods_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    methods_from_body(body)
  end

  defp handle_methods_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.warning("Polar payment-methods API returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp handle_methods_response({:error, exception}) do
    Logger.warning("Polar payment-methods API network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp methods_from_body(%{"items" => items}), do: summarize_methods(items)
  defp methods_from_body(items) when is_list(items), do: summarize_methods(items)

  defp methods_from_body(body) do
    Logger.error(
      "Polar payment-methods response is neither items-wrapped nor an array: #{inspect(body)}"
    )

    {:error, :invalid_response}
  end

  # The sweep needs existence + default, never the instruments: the
  # count gates the no-method flow, the default ref names what a
  # charge would hit.
  defp summarize_methods(items) do
    default = Enum.find(items, &default_method?/1)
    {:ok, length(items), method_ref(default)}
  end

  defp default_method?(%{"is_default" => true}), do: true
  defp default_method?(_other), do: false

  defp method_ref(nil), do: nil
  defp method_ref(%{"id" => id}) when is_binary(id), do: id
  defp method_ref(_malformed), do: nil

  # Draft only — NO success_url/return_url (there is no hosted flow
  # to return from); currency rides the product. OrderCreate takes
  # the SINGULAR product_id (the checkout body's `products` array is
  # a different endpoint's shape).
  defp draft_body(request, product_id, customer_id) do
    %{
      "customer_id" => customer_id,
      "product_id" => product_id,
      "amount" => request.amount_cents,
      "metadata" => %{"topup_id" => request.reference}
    }
  end

  defp handle_draft_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    draft_from_body(body)
  end

  defp handle_draft_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.warning("Polar draft-order API returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp handle_draft_response({:error, exception}) do
    Logger.warning("Polar draft-order API network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp draft_from_body(%{"id" => id} = body) when is_binary(id) do
    # Order responses carry no top-level `amount` — the money rides
    # subtotal_amount, the same field the webhook maps and S3's gross
    # guard keys on (contract point 1).
    with {:ok, amount_cents} <- parse_amount(body["subtotal_amount"]) do
      {:ok, %{order_id: id, amount_cents: amount_cents}}
    end
  end

  defp draft_from_body(body) do
    Logger.error("Polar draft-order response missing id: #{inspect(body)}")
    {:error, :invalid_response}
  end

  # 2xx finalize success is "paid" — any other 2xx status is
  # malformed gateway data (failures answer 4xx).
  defp handle_finalize_response({:ok, %Req.Response{status: status, body: body}}, order_id)
       when status in 200..299 do
    paid_outcome(body, order_id)
  end

  # 402 decline/no-method/SCA, 403 off-session not enabled, 412 not
  # draft — answered failures, never errors; the draft stays
  # re-finalizable and this adapter never re-drives it.
  defp handle_finalize_response({:ok, %Req.Response{status: status, body: body}}, order_id)
       when status in [402, 403, 412] do
    {:ok,
     %{
       order_id: order_id,
       amount_cents: amount_or_nil(body),
       status: :failed,
       failure_reason: failure_reason(status, body)
     }}
  end

  defp handle_finalize_response({:ok, %Req.Response{status: status, body: body}}, _order_id) do
    Logger.warning("Polar finalize API returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp handle_finalize_response({:error, exception}, _order_id) do
    Logger.warning("Polar finalize API network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp paid_outcome(%{"status" => "paid"} = body, order_id) do
    {:ok,
     %{
       order_id: order_id,
       amount_cents: amount_or_nil(body),
       status: :completed,
       failure_reason: nil
     }}
  end

  defp paid_outcome(body, _order_id) do
    Logger.error("Polar finalize response is not paid: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp handle_order_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    order_from_body(body)
  end

  defp handle_order_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.warning("Polar order API returned #{status}: #{inspect(body)}")
    {:error, :api_error}
  end

  defp handle_order_response({:error, exception}) do
    Logger.warning("Polar order API network error: #{inspect(exception)}")
    {:error, :network_error}
  end

  defp order_from_body(%{"id" => id} = body) when is_binary(id) do
    {:ok,
     %{
       order_id: id,
       status: order_status(body["status"]),
       amount_cents: amount_or_nil(body)
     }}
  end

  defp order_from_body(body) do
    Logger.error("Polar order response missing id: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp order_status(status), do: Map.get(@order_status_map, status, :unknown)

  # The order's money rides subtotal_amount (contract point 1 — the
  # field the webhook maps and S3's gross guard keys on); a failed
  # response may carry none.
  defp amount_or_nil(%{"subtotal_amount" => amount}) when is_integer(amount), do: amount
  defp amount_or_nil(_absent), do: nil

  defp failure_reason(status, body) do
    code = "http_" <> Integer.to_string(status)

    case short_reason(body) do
      nil -> code
      reason -> code <> ": " <> reason
    end
  end

  defp short_reason(%{"detail" => detail}) when is_binary(detail), do: detail
  defp short_reason(_unparseable), do: nil
end
