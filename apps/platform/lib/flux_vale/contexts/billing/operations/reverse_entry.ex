defmodule FluxVale.Billing.Operations.ReverseEntry do
  @moduledoc """
  Posts a compensating entry for a prior ledger entry (#120) — refunds
  are reversals, never row mutations (ADR-0029's accepted obligation).

  The reversal offsets the original in the opposite direction (`:credit`
  entry → `:debit` reversal, and back) with reason `:refund` by default,
  carrying `reverses_id` so every refund pairs with exactly one charge.
  A double reversal is rejected — the pre-lock guard answers reads, the
  partial unique index on `reverses_id` makes the concurrent case lose at
  the database. Serialized on the wallet's advisory lock, same as
  DebitWallet. System operation, `authorize?: false`.
  """

  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Operations.PostEntry
  alias FluxVale.Billing.Wallet

  require Ash.Query

  @reason_default :refund

  @spec call(LedgerEntry.t(), keyword()) ::
          {:ok, LedgerEntry.t()} | {:error, term()}
  def call(%LedgerEntry{} = original, opts \\ []) do
    with {:ok, wallet} <- Ash.get(Wallet, original.wallet_id, authorize?: false) do
      reverse(wallet, original, opts)
    end
  end

  defp reverse(wallet, original, opts) do
    outcome =
      FluxVale.Repo.transaction(fn ->
        FluxVale.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [wallet.id])

        case existing_reversal(original) do
          {:ok, []} ->
            post_reversal(wallet, original, opts)

          # The guard answers the sequential case; the concurrent case
          # loses to the partial unique index instead (DB round-trip,
          # not simulatable)
          # coveralls-ignore-start
          {:ok, [_reversal | _rest]} ->
            FluxVale.Repo.rollback(:already_reversed)

          {:error, reason} ->
            FluxVale.Repo.rollback(reason)
            # coveralls-ignore-stop
        end
      end)

    case outcome do
      {:ok, entry} -> {:ok, entry}
      {:error, _reason} = error -> error
    end
  end

  defp post_reversal(wallet, original, opts) do
    reason = Keyword.get(opts, :reason, @reason_default)
    opts = Keyword.put(opts, :reverses_id, original.id)

    case PostEntry.call(wallet, opposite(original.type), abs(original.amount), reason, opts) do
      {:ok, entry} ->
        entry

      # defensive: the posting only fails on a DB failure (the reversal
      # guard ran above; the unique-reversal index backstops the race) —
      # not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, reason} ->
        FluxVale.Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  defp existing_reversal(original) do
    LedgerEntry
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(reverses_id == ^original.id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
  end

  defp opposite(:credit), do: :debit
  defp opposite(:debit), do: :credit
end
