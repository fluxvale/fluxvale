defmodule FluxVale.Billing.Operations.CompleteTopup do
  @moduledoc """
  Completes a top-up from a verified gateway outcome — the one path
  that posts the wallet credit. Called by the provider's webhook
  controller and (M6 #137) the Confirmation step's reconciliation; both
  funnel through here so the credit lands exactly once per payment:
  `credit_wallet/3` with the outcome's idempotency key (the provider
  prefix travels with the caller — `"hitpay:<payment_id>"`).

  Resolution prefers the row at hand (`topup_id`: the confirmation
  path, and the webhook's `reference_number` fallback that heals an
  attach-then-crash window), then the payment-request id. An
  `:amount_mismatch` never credits — the row and the charge disagree,
  which is an operator signal, not a retry candidate.

  System operation, `authorize?: false` — inputs are verified gateway
  facts, not actor intents.
  """

  alias FluxVale.Billing.Operations.CreditWallet
  alias FluxVale.Billing.Topup
  alias FluxVale.Billing.Wallet

  require Ash.Query
  require Logger

  @type outcome :: %{
          required(:payment_request_id) => String.t(),
          required(:payment_id) => String.t(),
          required(:amount_cents) => pos_integer(),
          required(:idempotency_key) => String.t(),
          optional(:topup_id) => String.t()
        }

  @spec call(outcome()) ::
          {:ok, Topup.t()} | {:ok, :already_completed} | {:error, term()}
  def call(outcome) do
    with {:ok, topup} <- resolve_topup(outcome) do
      complete(topup, outcome)
    end
  end

  defp resolve_topup(%{topup_id: topup_id} = outcome) when is_binary(topup_id) do
    case Topup.get_by_id(topup_id, authorize?: false) do
      {:ok, topup} -> verify_request_binding(topup, outcome)
      {:error, _not_found} -> resolve_by_request(outcome)
    end
  end

  defp resolve_topup(outcome), do: resolve_by_request(outcome)

  # The row the reference named is not the row this payment belongs to —
  # cross-wired references must never credit the wrong org.
  defp verify_request_binding(%Topup{} = topup, outcome) do
    case topup.payment_request_id do
      nil ->
        {:ok, topup}

      request when request == outcome.payment_request_id ->
        {:ok, topup}

      _other ->
        {:error, :request_mismatch}
    end
  end

  defp resolve_by_request(outcome) do
    result =
      Topup
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(payment_request_id == ^outcome.payment_request_id)
      |> Ash.Query.limit(1)
      |> Ash.read(authorize?: false)

    case result do
      {:ok, [topup | _rest]} ->
        {:ok, topup}

      {:ok, []} ->
        {:error, :unknown_topup}

      # A read failure propagates rather than risking a mis-credit;
      # not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # A failed row never credits: a completed outcome contradicting a
  # failed record is an operator signal, not something to act on.
  # Completed rows fall through: the credit replays idempotently by
  # payment id and the guarded write below answers :already_completed.
  defp complete(%Topup{status: :failed} = topup, _outcome) do
    Logger.error("Completed payment for a failed top-up #{topup.id} — not crediting")
    {:error, :topup_failed}
  end

  defp complete(%Topup{} = topup, outcome) do
    if outcome.amount_cents == topup.amount_cents do
      post_credit(topup, outcome)
    else
      Logger.error(
        "Top-up #{topup.id} amount mismatch: row #{topup.amount_cents}¢, " <>
          "payment #{outcome.amount_cents}¢ — not crediting"
      )

      {:error, :amount_mismatch}
    end
  end

  defp post_credit(topup, outcome) do
    # The wallet exists before a top-up can (the billing surface
    # provisions it on mount); resolving by org id avoids a
    # relationship load on the credit path.
    result =
      with {:ok, wallet} <- Wallet.get_by_organization(topup.organization_id, authorize?: false) do
        CreditWallet.call(wallet, topup.amount_cents, idempotency_key: outcome.idempotency_key)
      end

    case result do
      {:ok, _entry} -> mark_completed(topup, outcome)
      {:error, _reason} = error -> error
    end
  end

  # Terminal-once: the status filter rides the UPDATE's WHERE, so an
  # out-of-order delivery racing this write loses (zero rows) instead
  # of flipping an already-terminal row.
  defp mark_completed(topup, outcome) do
    query = Ash.Query.filter(Topup, id == ^topup.id and status == :pending)

    result =
      Ash.bulk_update(
        query,
        :mark_completed,
        %{payment_id: outcome.payment_id, payment_request_id: outcome.payment_request_id},
        authorize?: false,
        return_records?: true,
        notify?: false
      )

    case result do
      %Ash.BulkResult{status: :success, records: [completed]} ->
        {:ok, completed}

      %Ash.BulkResult{status: :success, records: []} ->
        {:ok, :already_completed}

      # DB-level failure — not simulatable under the sandbox; a webhook
      # retry replays the idempotent credit and lands here again.
      # coveralls-ignore-next-line
      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end
end
