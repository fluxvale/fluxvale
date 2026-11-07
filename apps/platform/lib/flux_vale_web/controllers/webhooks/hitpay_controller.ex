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
  alias FluxVale.Billing.TopupOutcomeMail
  alias FluxValeWeb.Webhooks.Plumbing

  require Logger

  @signature_header "hitpay-signature"

  @terminal_outcomes [:unknown_topup, :amount_mismatch, :request_mismatch, :topup_failed]

  @doc "Handles an incoming HitPay webhook."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    case verify(conn) do
      {:ok, payload} ->
        result = process_event(payload)
        Plumbing.respond(result, conn, "HitPay", @terminal_outcomes)

      {:error, error} ->
        Plumbing.verify_error(conn, error, "HitPay", "salt")
    end
  end

  # Signature verification over the exact request bytes (RawBody) —
  # everything downstream runs only on verified facts.
  @spec verify(Plug.Conn.t()) :: {:ok, map()} | {:error, term()}
  defp verify(conn) do
    with {:ok, raw_body} <- Plumbing.read_raw_body(conn),
         :ok <- HitPay.verify_webhook(raw_body, signature(conn)) do
      Plumbing.parse_payload(raw_body)
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

        # The outcome mail rides the fresh transition only (#377) —
        # the operation's terminal-once guard makes replays answer
        # :already_completed and mail nothing.
        result = Billing.complete_topup(outcome)
        TopupOutcomeMail.on_completion(result)

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
    result = Billing.fail_topup(payment_request_id)
    TopupOutcomeMail.on_failure(result)
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

  @spec signature(Plug.Conn.t()) :: String.t() | nil
  defp signature(conn) do
    conn
    |> get_req_header(@signature_header)
    |> List.first()
  end
end
