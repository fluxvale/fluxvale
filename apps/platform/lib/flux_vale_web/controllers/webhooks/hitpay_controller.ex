defmodule FluxValeWeb.Webhooks.HitPayController do
  @moduledoc """
  Receives HitPay event webhooks — the v1 DodoWebhookController's port
  to the HitPay scheme (#136, ADR-0029).

  Route: `POST /webhooks/hitpay` (per-provider, unauthenticated :api
  pipeline — the caller is HitPay; auth is the HMAC signature, verified
  constant-time over the raw body captured by RawBody). The endpoint is
  dashboard-registered (Developers → Webhooks) for
  `payment_request.completed` / `payment_request.failed`, which sign
  with the per-webhook salt — not the legacy API-key salt.

  ## Responses

  - 200 for every valid-signature delivery, whatever the payload:
    unknown events and terminal mismatches won't improve on retry, and
    HitPay retries non-2xx.
  - 401 on signature failure (missing signature / mismatch) — a forged
    delivery learns nothing but the rejection.
  - 500 in three cases: a missing webhook salt (misconfigured — an
    operator signal, not a gateway fault), a delivery with no raw body
    to verify (empty body or an unparsed content type), and a credit
    that failed on a payment we accepted (DB failure) — the one case
    where HitPay's retry heals us.

  ## Idempotency

  The credit posts with `hitpay:<payment_id>` (CompleteTopup): a
  replayed delivery replays to the same ledger entry, never a double
  credit — HitPay's scheme has no timestamp to window, so idempotency
  is the replay defense (settled on #136).
  """

  use FluxValeWeb, :controller

  alias FluxVale.Billing
  alias FluxVale.Billing.Providers.HitPay

  require Logger

  @signature_header "hitpay-signature"

  @terminal_outcomes [:unknown_topup, :amount_mismatch, :request_mismatch, :topup_failed]

  @doc "Handles an incoming HitPay webhook."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    case verify(conn) do
      {:ok, payload} ->
        result = process_event(payload)
        respond(result, conn)

      {:error, :no_raw_body} ->
        Logger.error("HitPay webhook rejected: no raw body in conn (RawBody plug misconfigured)")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "misconfigured"})

      {:error, verification} when verification in [:missing_signature, :signature_mismatch] ->
        Logger.warning("HitPay webhook rejected: #{inspect(verification)}")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_signature"})

      {:error, :missing_config} ->
        Logger.error("HitPay webhook rejected: webhook salt not configured")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "misconfigured"})

      {:error, :invalid_json} ->
        # Valid signature, unusable payload — retrying won't help.
        Logger.warning("HitPay webhook rejected: invalid JSON payload")
        json(conn, %{received: true})
    end
  end

  # Signature verification over the exact request bytes (RawBody) —
  # everything downstream runs only on verified facts.
  @spec verify(Plug.Conn.t()) :: {:ok, map()} | {:error, term()}
  defp verify(conn) do
    with {:ok, raw_body} <- read_raw_body(conn),
         :ok <- HitPay.verify_webhook(raw_body, signature(conn)) do
      parse_payload(raw_body)
    end
  end

  @spec process_event(map()) ::
          {:ok, FluxVale.Billing.Topup.t()}
          | {:ok, :already_completed | :already_terminal}
          | :ok
          | {:error, term()}
  defp process_event(%{"status" => "completed", "id" => payment_request_id} = payload) do
    case HitPay.succeeded_payment(payload["payments"]) do
      {:ok, payment} ->
        outcome = %{
          payment_request_id: payment_request_id,
          payment_id: payment.id,
          amount_cents: payment.amount_cents,
          idempotency_key: HitPay.idempotency_key(payment.id),
          topup_id: payload["reference_number"]
        }

        Billing.complete_topup(outcome)

      :none ->
        # Completed request without a parseable succeeded payment —
        # nothing to credit; ack so the delivery stops retrying.
        Logger.warning(
          "HitPay completed event without a succeeded payment: #{payment_request_id}"
        )

        :ok
    end
  end

  defp process_event(%{"status" => "failed", "id" => payment_request_id}) do
    Billing.fail_topup(payment_request_id)
  end

  defp process_event(%{"status" => status} = payload) do
    # pending/processing/cancelled… — acknowledged, nothing to do.
    Logger.info("HitPay webhook unhandled status #{status}: #{payload["id"]}")
    :ok
  end

  defp process_event(payload) do
    # Payloads carry buyer PII — id and shape only, never the body.
    Logger.warning(
      "HitPay webhook payload without status field: #{inspect(payload["id"])} " <>
        "keys=#{inspect(Map.keys(payload))}"
    )

    :ok
  end

  @spec respond(term(), Plug.Conn.t()) :: Plug.Conn.t()
  defp respond(result, conn) do
    case result do
      {:ok, _result} ->
        json(conn, %{received: true})

      :ok ->
        json(conn, %{received: true})

      # Terminal mismatches — retrying can't change them; the error log
      # is the operator signal.
      {:error, reason} when reason in @terminal_outcomes ->
        Logger.error("HitPay webhook not credited, #{inspect(reason)}")
        json(conn, %{received: true})

      # A credit that failed on a payment we accepted — 500 so HitPay
      # retries (the idempotency key makes the retry safe).
      {:error, reason} ->
        Logger.error("HitPay webhook credit failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "internal_error"})
    end
  end

  @spec read_raw_body(Plug.Conn.t()) :: {:ok, binary()} | {:error, :no_raw_body}
  defp read_raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and byte_size(body) > 0 -> {:ok, body}
      _empty -> {:error, :no_raw_body}
    end
  end

  @spec parse_payload(binary()) :: {:ok, map()} | {:error, :invalid_json}
  defp parse_payload(raw_body) do
    case Phoenix.json_library().decode(raw_body) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _non_object} -> {:error, :invalid_json}
      # Unreachable through the endpoint: Plug.Parsers raises ParseError
      # (400) on undecodable bodies before the router. Defense-in-depth
      # for callers of the controller outside the endpoint pipeline.
      # coveralls-ignore-next-line
      {:error, _decode_error} -> {:error, :invalid_json}
    end
  end

  @spec signature(Plug.Conn.t()) :: String.t() | nil
  defp signature(conn) do
    conn
    |> get_req_header(@signature_header)
    |> List.first()
  end
end
