defmodule FluxVale.Billing.Operations.ReconcileTopup do
  @moduledoc """
  Reconciles a pending top-up against the gateway — the Confirmation
  step's fallback when the webhook hasn't landed yet (#137). Both paths
  funnel into `CompleteTopup`/`FailTopup`, so the credit posts exactly
  once per payment regardless of who asks first; the webhook stays the
  source of truth, this is just promptness.

  Fetches the payment request through the active provider; a completed
  request **naming the same payment request** with a succeeded charge
  completes the top-up, a terminal failure fails it, anything else
  (pending, mismatched response, gateway error) leaves the row for the
  webhook. System operation, `authorize?: false`.
  """

  alias FluxVale.Billing.Operations.CompleteTopup
  alias FluxVale.Billing.Operations.FailTopup

  @spec call(String.t()) ::
          {:ok, FluxVale.Billing.Topup.t()}
          | {:ok, :already_completed}
          | {:ok, :already_terminal}
          | {:ok, :pending}
          | {:error, term()}
  def call(payment_request_id) when is_binary(payment_request_id) do
    provider = Application.fetch_env!(:flux_vale, :payments_provider)

    case provider.fetch_payment(payment_request_id) do
      {:ok, %{status: status} = payment} when is_atom(status) ->
        dispatch(provider, payment_request_id, payment)

      {:error, reason} ->
        # The row stays pending — the webhook owns the outcome; a
        # gateway hiccup here must not mark anything failed.
        {:error, reason}
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
