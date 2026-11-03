defmodule FluxVale.Billing.Providers.Polar do
  @moduledoc """
  Polar gateway (#377, ADR-0029's second provider) — hosted
  custom-price checkouts over the Checkout Sessions API, Standard
  Webhooks event deliveries.

  Sandbox first (the org token is minted per Polar environment):
  `server` defaults to "sandbox"; production flips via `POLAR_SERVER`
  at the gated cutover (#377 S4). Config block `config :flux_vale,
  :polar` — `access_token`, `webhook_secret`, `server`, `product_id`
  — resolved from env by runtime.exs (BWS in cluster, ADR-0021),
  never committed.

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
  """

  @behaviour FluxVale.Billing.PaymentProvider

  alias FluxVale.Billing.PaymentProvider

  require Logger

  @config_key :polar

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

  @impl PaymentProvider
  @spec create_checkout(PaymentProvider.checkout_request(), keyword()) ::
          {:ok, PaymentProvider.checkout()} | {:error, PaymentProvider.error()}
  def create_checkout(request, opts) do
    config = Keyword.merge(env_config(), opts)

    with {:ok, access_token} <- fetch_config(config, :access_token),
         {:ok, product_id} <- fetch_config(config, :product_id),
         {:ok, base_url} <- base_url(config) do
      req = Req.new(base_url: base_url, headers: [{"authorization", "bearer " <> access_token}])

      req
      |> Req.post(url: "/v1/checkouts/", json: checkout_body(request, product_id))
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
    config = env_config()

    with {:ok, access_token} <- fetch_config(config, :access_token),
         {:ok, base_url} <- base_url(config) do
      req = Req.new(base_url: base_url, headers: [{"authorization", "bearer " <> access_token}])

      # Percent-encode: an id carrying ../, ?, or # (a hostile or
      # malformed webhook) must not retarget the GET. Item paths
      # take no trailing slash (collections do — Polar 404s the swap).
      encoded = URI.encode(checkout_id, &URI.char_unreserved?/1)

      req
      |> Req.get(url: "/v1/checkouts/#{encoded}")
      |> handle_payment_response()
    end
  end

  @doc """
  The ledger idempotency key for a Polar payment (ADR-0029: the
  provider-prefixed payment id — here the checkout session id,
  contract point 2, #377).
  """
  @spec idempotency_key(String.t()) :: String.t()
  def idempotency_key(checkout_id) when is_binary(checkout_id), do: "polar:" <> checkout_id

  defp checkout_body(request, product_id) do
    base = %{
      "products" => [product_id],
      "amount" => request.amount_cents,
      "currency" => String.downcase(request.currency),
      "success_url" => request.redirect_url,
      "metadata" => %{"topup_id" => request.reference}
    }

    Map.merge(base, buyer_fields(request))
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
end
