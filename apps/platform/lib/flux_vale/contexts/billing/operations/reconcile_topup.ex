defmodule FluxVale.Billing.Operations.ReconcileTopup do
  @moduledoc """
  Reconciles a pending top-up against the gateway — the Confirmation
  step's fallback when the webhook hasn't landed yet (#137). Both paths
  funnel into `CompleteTopup`/`FailTopup`, so the credit posts exactly
  once per payment regardless of who asks first; the webhook stays the
  source of truth, this is just promptness.

  Fetches the payment through the active provider; a completed
  request **naming the same payment request** with a succeeded charge
  completes the top-up, a terminal failure fails it, anything else
  (pending, mismatched response, gateway error) leaves the row for the
  webhook. System operation, `authorize?: false`.

  ## Lanes

  The lane chooses the fetch (the caller knows what its row's id is):

  - `:checkout` (default) — a checkout session id, fetched with
    `fetch_payment/1`. The wizard lane's path, unchanged since #137.
  - `:order` (#829 S4) — an ORDER id (the auto-recharge lane attaches
    its draft order id), fetched with `fetch_order/1`: `fetch_payment/1`
    reads the checkout endpoint, where an order id 404s. `:paid`
    completes through the same idempotent credit (the order id is the
    payment identity on Polar — `payment_id` and the
    `polar:<order_id>` key, exactly the webhook arm's seam); a still
    `:draft` order answers `{:ok, :unfinalized}` (an unfinalized draft
    can never have charged — safe to fail, the CALLER flips it);
    anything else (unknown status, paid without a usable amount,
    gateway fault) leaves the row for the order.paid webhook, like the
    checkout lane's pending arm.
  """

  alias FluxVale.Billing.Operations.CompleteTopup
  alias FluxVale.Billing.Operations.FailTopup
  alias FluxVale.Billing.Topup

  @type lane :: :checkout | :order

  @spec call(String.t()) ::
          {:ok, Topup.t()}
          | {:ok, :already_completed}
          | {:ok, :already_terminal}
          | {:ok, :pending}
          | {:error, term()}
  @spec call(String.t(), lane()) ::
          {:ok, Topup.t()}
          | {:ok, :already_completed}
          | {:ok, :already_terminal}
          | {:ok, :pending}
          | {:ok, :unfinalized}
          | {:error, term()}
  def call(payment_request_id, lane \\ :checkout) when is_binary(payment_request_id) do
    provider = Application.fetch_env!(:flux_vale, :payments_provider)

    case lane do
      :checkout ->
        case provider.fetch_payment(payment_request_id) do
          {:ok, %{status: status} = payment} when is_atom(status) ->
            dispatch(provider, payment_request_id, payment)

          {:error, reason} ->
            # The row stays pending — the webhook owns the outcome; a
            # gateway hiccup here must not mark anything failed.
            {:error, reason}
        end

      :order ->
        case provider.fetch_order(payment_request_id) do
          {:ok, %{status: :paid, amount_cents: amount_cents}} when is_integer(amount_cents) ->
            # The order id is the payment identity on Polar (contract
            # point 2, the webhook arm's seam): payment_id and the
            # idempotency key both carry it, so this converges on one
            # credit.
            CompleteTopup.call(%{
              payment_request_id: payment_request_id,
              payment_id: payment_request_id,
              amount_cents: amount_cents,
              idempotency_key: provider.idempotency_key(payment_request_id)
            })

          {:ok, %{status: :draft}} ->
            # A still-draft order was never finalized — nothing can
            # have charged; the caller fails the row.
            {:ok, :unfinalized}

          # A paid order without a usable amount, or a status this
          # adapter does not know — the order.paid webhook owns it.
          {:ok, %{status: _pending_or_unusable}} ->
            {:ok, :pending}

          {:error, reason} ->
            # The row stays pending — a gateway fault (including a 404)
            # must never fail a possibly-charged row; the next pass
            # retries.
            {:error, reason}
        end
    end
  end

  defp dispatch(provider, payment_request_id, %{status: :completed} = payment) do
    # A response naming a different payment request must not credit
    # the row we asked about — leave it for the webhook, like any
    # other unusable answer.
    if payment.payment_request_id == payment_request_id do
      complete(provider, payment_request_id, payment)
    else
      {:ok, :pending}
    end
  end

  defp dispatch(_provider, payment_request_id, %{status: status})
       when status in [:failed, :cancelled, :expired] do
    FailTopup.call(payment_request_id)
  end

  defp dispatch(_provider, _payment_request_id, %{status: _pending_or_unknown}) do
    {:ok, :pending}
  end

  defp complete(provider, payment_request_id, payment) do
    case succeeded(payment) do
      %{id: id, amount_cents: amount_cents} ->
        CompleteTopup.call(%{
          payment_request_id: payment_request_id,
          payment_id: id,
          amount_cents: amount_cents,
          idempotency_key: provider.idempotency_key(id)
        })

      :none ->
        # Completed request, no succeeded charge yet — the webhook
        # finishes this; nothing to reconcile now.
        {:ok, :pending}
    end
  end

  # Mirrors the webhook path's succeeded-charge discipline: a binary id
  # is part of being a usable charge (the idempotency key names it).
  defp succeeded(%{payments: payments}) when is_list(payments) do
    charge =
      Enum.find(payments, fn payment ->
        match?(%{id: id, status: :succeeded} when is_binary(id), payment)
      end)

    charge || :none
  end
end
