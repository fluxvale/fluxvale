defmodule FluxVale.Billing.Operations.FailTopup do
  @moduledoc """
  Marks a top-up `:failed` from a gateway failure report (webhook
  `payment_request.failed`, or the Confirmation step's reconciliation
  seeing a failed/cancelled fetch). Idempotent — a terminal row stays
  put; unknown ids answer `:unknown_topup` so the caller can ack and
  move on. No credit ever posts from this path. System operation,
  `authorize?: false`.
  """

  alias FluxVale.Billing.Topup

  require Ash.Query

  @spec call(String.t()) ::
          {:ok, Topup.t()} | {:ok, :already_terminal} | {:error, term()}
  def call(payment_request_id) when is_binary(payment_request_id) do
    case fetch_topup(payment_request_id) do
      {:ok, topup} -> fail(topup)
      {:error, _reason} = error -> error
    end
  end

  # Terminal-once: the status filter rides the UPDATE's WHERE, so a
  # completed row never turns failed — the guard, not an Elixir
  # pre-check, decides (the out-of-order-delivery answer).
  defp fail(topup) do
    query = Ash.Query.filter(Topup, id == ^topup.id and status == :pending)

    result =
      Ash.bulk_update(query, :mark_failed, %{},
        authorize?: false,
        return_records?: true,
        notify?: false
      )

    case result do
      %Ash.BulkResult{status: :success, records: [failed]} ->
        {:ok, failed}

      %Ash.BulkResult{status: :success, records: []} ->
        {:ok, :already_terminal}

      # DB-level failure — not simulatable under the sandbox (the same
      # class as PostEntry's insert arm); the retry path re-runs this.
      # coveralls-ignore-next-line
      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp fetch_topup(payment_request_id) do
    result =
      Topup
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(payment_request_id == ^payment_request_id)
      |> Ash.Query.limit(1)
      |> Ash.read(authorize?: false)

    case result do
      {:ok, [topup | _rest]} ->
        {:ok, topup}

      {:ok, []} ->
        {:error, :unknown_topup}

      # A read failure propagates — failing a top-up on a DB hiccup
      # would mark unpaid rows failed; not simulatable under the sandbox.
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end
end
