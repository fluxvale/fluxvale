defmodule FluxValeWeb.Webhooks.PolarController do
  @moduledoc """
  Receives Polar event webhooks — the Standard Webhooks counterpart
  of HitPayController (#377, ADR-0029).

  Route: `POST /webhooks/polar` (per-provider, unauthenticated :api
  pipeline — the caller is Polar; auth is the HMAC signature over
  `"<webhook-id>.<webhook-timestamp>.<raw body>"`, verified
  constant-time on the raw bytes captured by RawBody). The endpoint
  is dashboard-registered for `order.paid` +
  `customer.state_changed`.

  ## Responses

  - 200 for every valid-signature delivery, whatever the payload:
    unknown events and terminal mismatches won't improve on retry,
    and Polar retries non-2xx.
  - 401 on signature failure — a partial three-header set never
    reaches verify (only the exact composition could succeed); a
    forged delivery learns nothing but the rejection.
  - 500 in three cases: a missing webhook secret (misconfigured —
    an operator signal, not a gateway fault), a delivery with no
    raw body to verify (empty body or an unparsed content type),
    and a credit that failed on a payment we accepted (DB failure)
    — the one case where Polar's retry heals us.

  ## Idempotency

  The credit posts with `polar:<checkout_id>` (CompleteTopup): the
  checkout session id is the payment identity on BOTH the webhook
  and the reconcile path (contract point 2, #377) — a replayed
  delivery replays to the same ledger entry, never a double
  credit; the ±5-minute timestamp window is replay defense number
  one.
  """

  use FluxValeWeb, :controller

  alias FluxVale.Billing
  alias FluxVale.Billing.Providers.Polar
  alias FluxVale.Billing.TopupOutcomeMail
  alias FluxValeWeb.Webhooks.Plumbing

  require Logger

  @terminal_outcomes [:unknown_topup, :amount_mismatch, :request_mismatch, :topup_failed]

  @doc "Handles an incoming Polar webhook."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    case verify(conn) do
      {:ok, payload} ->
        result = process_event(payload)
        Plumbing.respond(result, conn, "Polar", @terminal_outcomes)

      {:error, error} ->
        Plumbing.verify_error(conn, error, "Polar", "secret")
    end
  end

  # Signature verification over the exact request bytes (RawBody) —
  # everything downstream runs only on verified facts.
  @spec verify(Plug.Conn.t()) :: {:ok, map()} | {:error, term()}
  defp verify(conn) do
    with {:ok, raw_body} <- Plumbing.read_raw_body(conn),
         {:ok, composed} <- composed_signature(conn),
         :ok <- Polar.verify_webhook(raw_body, composed) do
      Plumbing.parse_payload(raw_body)
    end
  end

  # Standard Webhooks spreads the signature material over three
  # headers; the adapter takes them dot-joined in signed order
  # (uuids, unix timestamps, and base64 are dot-free — the join is
  # unambiguous). A partial set is rejected before verify: a
  # composition that could succeed must be exact.
  @spec composed_signature(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_signature}
  defp composed_signature(conn) do
    with [id] <- get_req_header(conn, "webhook-id"),
         [ts] <- get_req_header(conn, "webhook-timestamp"),
         [sig] <- get_req_header(conn, "webhook-signature") do
      {:ok, id <> "." <> ts <> "." <> sig}
    else
      _partial -> {:error, :missing_signature}
    end
  end

  @spec process_event(map()) ::
          {:ok, FluxVale.Billing.Topup.t()}
          | {:ok, :already_completed | :already_terminal}
          | :ok
          | {:error, term()}
  defp process_event(%{"type" => "order.paid", "data" => data} = payload) when is_map(data) do
    case credit_outcome(data) do
      {:ok, outcome} ->
        # The outcome mail rides the fresh transition only (#377) —
        # the operation's terminal-once guard makes replays answer
        # :already_completed and mail nothing.
        result = Billing.complete_topup(outcome)
        TopupOutcomeMail.on_completion(result)

      :none ->
        # Order.paid without a usable checkout id or subtotal —
        # nothing to credit; ack so the delivery stops retrying.
        Logger.warning(
          "Polar order.paid without usable checkout_id/subtotal_amount: " <>
            "#{inspect(payload["data"]["id"])}"
        )

        :ok
    end
  end

  defp process_event(%{"type" => "customer.state_changed"} = payload) do
    # Future work (#377, out of S2): customer-portal state sync lands
    # with the portal slice — acknowledged, nothing invented.
    Logger.info(
      "Polar customer.state_changed acknowledged: #{inspect(get_in(payload, ["data", "id"]))}"
    )

    :ok
  end

  defp process_event(%{"type" => type} = payload) do
    # subscription.created, refund.paid… — acknowledged, nothing to do.
    Logger.info("Polar webhook unhandled type #{type}: #{inspect(payload["data"]["id"])}")
    :ok
  end

  defp process_event(payload) do
    # Payloads carry buyer PII — type and shape only, never the body.
    Logger.warning("Polar webhook payload without type field: keys=#{inspect(Map.keys(payload))}")

    :ok
  end

  # Contract point 1 (#377): `subtotal_amount` is discount-invariant
  # — exactly the amount the checkout set, unchanged by Polar's tax
  # carve-out AND by applied discounts. `total_amount` equals our
  # gross only under tax-inclusive-no-discount; discounts make it
  # diverge, so only the subtotal can meet the guard on every
  # charge. Contract point 2: the checkout id is the payment
  # identity everywhere — request id, payment id, idempotency key.
  @spec credit_outcome(map()) :: {:ok, map()} | :none
  defp credit_outcome(data) do
    checkout_id = data["checkout_id"]
    subtotal = data["subtotal_amount"]

    if is_binary(checkout_id) and checkout_id != "" and is_integer(subtotal) do
      {:ok, outcome(data, checkout_id, subtotal)}
    else
      :none
    end
  end

  defp outcome(data, checkout_id, subtotal) do
    base = %{
      payment_request_id: checkout_id,
      payment_id: checkout_id,
      amount_cents: subtotal,
      idempotency_key: Polar.idempotency_key(checkout_id)
    }

    case get_in(data, ["metadata", "topup_id"]) do
      topup_id when is_binary(topup_id) and topup_id != "" -> Map.put(base, :topup_id, topup_id)
      _absent -> base
    end
  end
end
