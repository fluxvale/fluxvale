defmodule FluxVale.Billing.Providers.HitPay do
  @moduledoc """
  HitPay gateway (ADR-0029 Am. 2) — hosted checkout over the Payment
  Request API, event webhooks with per-webhook-salt HMAC signatures.

  Test mode first (the registrations gate blocks production charges):
  `base_url` defaults to the sandbox; production flips via
  `HITPAY_BASE_URL` when the gate lifts (#142). Config block
  `config :flux_vale, :hitpay` — `api_key`, `webhook_salt`, `base_url` —
  resolved from env by runtime.exs (BWS in cluster, ADR-0021), never
  committed.

  ## Webhook signature

  Event webhooks (dashboard-registered, `payment_request.completed`)
  sign the raw body with HMAC-SHA256 hex in the `hitpay-signature`
  header, keyed by that endpoint's salt — verified with
  `Plug.Crypto.secure_compare/2`. HitPay's scheme carries no timestamp,
  so Dodo's replay-window check has no equivalent here; replay safety is
  the ledger's payment-id idempotency key, which makes a replayed
  delivery a no-op by construction (settled on #136).

  ## Wire format notes

  The API is form-encoded (`amount` is a decimal string like "12.00")
  and auth rides `X-BUSINESS-API-KEY` — not Bearer. Checkout creation
  sends `allow_repeated_payments=false` so exactly one payment can land
  per request; the idempotency key names that payment.
  """

  @behaviour FluxVale.Billing.PaymentProvider

  alias FluxVale.Billing.PaymentProvider

  require Logger

  @config_key :hitpay

  # Payment-request statuses ("completed"/"failed"/…) plus payment-row
  # statuses ("succeeded") — one vocabulary for normalization.
  @status_map %{
    "pending" => :pending,
    "processing" => :pending,
    "completed" => :completed,
    "succeeded" => :succeeded,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "canceled" => :cancelled,
    "expired" => :expired
  }

  @impl PaymentProvider
  @spec create_checkout(PaymentProvider.checkout_request(), keyword()) ::
          {:ok, PaymentProvider.checkout()} | {:error, PaymentProvider.error()}
  def create_checkout(request, opts) do
    config = Keyword.merge(env_config(), opts)

    with {:ok, api_key} <- fetch_config(config, :api_key),
         {:ok, base_url} <- fetch_config(config, :base_url) do
      req = Req.new(base_url: base_url, headers: [{"x-business-api-key", api_key}])

      req
      |> Req.post(url: "/v1/payment-requests", form: checkout_form(request))
      |> handle_checkout_response()
    end
  end

  @impl PaymentProvider
  @spec verify_webhook(binary(), String.t() | nil) ::
          :ok | {:error, :missing_signature | :missing_config | :signature_mismatch}
  def verify_webhook(raw_body, signature) when is_binary(raw_body) do
    with {:ok, signature} <- fetch_signature(signature),
         {:ok, salt} <- fetch_config(env_config(), :webhook_salt) do
      expected =
        :hmac
        |> :crypto.mac(:sha256, salt, raw_body)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(signature, expected) do
        :ok
      else
        {:error, :signature_mismatch}
      end
    end
  end

  @impl PaymentProvider
  @spec fetch_payment(String.t()) ::
          {:ok, PaymentProvider.payment()} | {:error, PaymentProvider.error()}
  def fetch_payment(payment_request_id) when is_binary(payment_request_id) do
    config = env_config()

    with {:ok, api_key} <- fetch_config(config, :api_key),
         {:ok, base_url} <- fetch_config(config, :base_url) do
      req = Req.new(base_url: base_url, headers: [{"x-business-api-key", api_key}])

      # Percent-encode: an id carrying ../, ?, or # (a hostile or
      # malformed webhook) must not retarget the GET.
      encoded = URI.encode(payment_request_id, &URI.char_unreserved?/1)

      req
      |> Req.get(url: "/v1/payment-requests/#{encoded}")
      |> handle_payment_response()
    end
  end

  @doc "The ledger idempotency key for a HitPay payment (ADR-0029: provider-prefixed payment id)."
  @spec idempotency_key(String.t()) :: String.t()
  def idempotency_key(payment_id) when is_binary(payment_id), do: "hitpay:" <> payment_id

  @doc """
  The succeeded charge of a completed payment request — the webhook's
  credit facts. `:none` when no parseable succeeded payment rides the
  payload (nothing to credit; the caller acks and logs).
  """
  @spec succeeded_payment(list(term()) | nil) ::
          {:ok, %{id: String.t(), amount_cents: pos_integer()}} | :none
  def succeeded_payment(payments) when is_list(payments) do
    result =
      Enum.find(payments, fn payment ->
        is_map(payment) and payment["status"] == "succeeded" and is_binary(payment["id"])
      end)

    normalize_succeeded(result)
  end

  # Absent payments list — no charge to read.
  def succeeded_payment(_none), do: :none

  defp normalize_succeeded(%{"amount" => amount} = payment) when is_binary(amount) do
    case parse_amount(amount) do
      {:ok, cents} when cents > 0 -> {:ok, %{id: payment["id"], amount_cents: cents}}
      _unusable -> :none
    end
  end

  # A succeeded payment without a usable amount — treat as absent.
  defp normalize_succeeded(_payment), do: :none

  defp checkout_form(request) do
    form = [
      {"amount", format_amount(request.amount_cents)},
      {"currency", request.currency},
      {"reference_number", request.reference},
      {"redirect_url", request.redirect_url},
      {"allow_repeated_payments", "false"}
    ]

    buyer_fields = [
      {"email", request[:email]},
      {"name", request[:name]}
    ]

    buyer_fields
    |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
    |> Enum.concat(form)
  end

  # "12.00" from integer cents — string math, never floats near money.
  defp format_amount(cents) do
    remainder = rem(cents, 100)
    remainder_str = Integer.to_string(remainder)
    padded = String.pad_leading(remainder_str, 2, "0")
    "#{div(cents, 100)}.#{padded}"
  end

  defp fetch_signature(signature) when is_binary(signature) and signature != "",
    do: {:ok, signature}

  defp fetch_signature(_missing), do: {:error, :missing_signature}

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
        Logger.warning("HitPay checkout API returned #{status}: #{inspect(body)}")
        {:error, :api_error}

      {:error, exception} ->
        Logger.warning("HitPay checkout API network error: #{inspect(exception)}")
        {:error, :network_error}
    end
  end

  defp checkout_from_body(%{"id" => id, "url" => url}) when is_binary(id) and is_binary(url) do
    {:ok, %{payment_request_id: id, checkout_url: url}}
  end

  defp checkout_from_body(body) do
    Logger.error("HitPay checkout response missing id/url: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp handle_payment_response(result) do
    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        payment_from_body(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("HitPay payment API returned #{status}: #{inspect(body)}")
        {:error, :api_error}

      {:error, exception} ->
        Logger.warning("HitPay payment API network error: #{inspect(exception)}")
        {:error, :network_error}
    end
  end

  defp payment_from_body(%{"id" => id} = body) when is_binary(id) do
    with {:ok, amount_cents} <- parse_amount(body["amount"]),
         {:ok, payments} <- normalize_payments(body["payments"]) do
      {:ok,
       %{
         payment_request_id: id,
         status: status(body["status"]),
         amount_cents: amount_cents,
         payments: payments
       }}
    end
  end

  defp payment_from_body(body) do
    Logger.error("HitPay payment response missing id: #{inspect(body)}")
    {:error, :invalid_response}
  end

  # A malformed payment row is an :invalid_response, never a crash —
  # reconciliation must answer, not raise, on unexpected gateway data.
  defp normalize_payments(payments) when is_list(payments) do
    result =
      Enum.reduce_while(payments, [], fn payment, acc ->
        case parse_amount(payment["amount"]) do
          {:ok, cents} ->
            row = %{id: payment["id"], status: status(payment["status"]), amount_cents: cents}
            {:cont, [row | acc]}

          {:error, _reason} ->
            {:halt, {:error, :invalid_response}}
        end
      end)

    case result do
      rows when is_list(rows) -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  # Absent payments list — the request has no charge yet.
  defp normalize_payments(_none), do: {:ok, []}

  defp status(value) do
    Map.get(@status_map, value, :unknown)
  end

  # "100.00" -> 10000 — string math (floats never touch money).
  defp parse_amount(amount) when is_binary(amount) do
    case String.split(amount, ".") do
      [dollars, decimals] ->
        padded = String.pad_trailing(decimals, 2, "0")
        cents = binary_part(padded, 0, 2)
        parse_cents(dollars, cents)

      [dollars] ->
        parse_cents(dollars, "0")

      _malformed ->
        {:error, :invalid_response}
    end
  end

  # A non-binary amount (null, number) is a malformed response, not a crash.
  defp parse_amount(_malformed), do: {:error, :invalid_response}

  defp parse_cents(dollars, cents) do
    # Integer.parse drops a leading sign only for "-0"/"+0" — reject
    # negatives on the string so "-0.99" can't sneak in as +99¢.
    if String.starts_with?(dollars, "-") or String.starts_with?(cents, "-") do
      {:error, :invalid_response}
    else
      case {Integer.parse(dollars), Integer.parse(cents)} do
        {{dollars, ""}, {cents, ""}} when dollars >= 0 and cents >= 0 ->
          {:ok, dollars * 100 + cents}

        _malformed ->
          {:error, :invalid_response}
      end
    end
  end
end
