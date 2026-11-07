defmodule FluxVale.Billing.Operations.ReverseEntry do
  @moduledoc """
  Posts a compensating entry for a prior ledger entry (#120) — refunds
  are reversals, never row mutations (ADR-0029's accepted obligation).

  The reversal offsets the original in the opposite direction (`:credit`
  entry → `:debit` reversal, and back) with reason `:refund` by default,
  carrying `reverses_id` so every refund pairs with exactly one charge.
  The original's tax facts (country/state/rate/collected tax/marker,
  gate 3) ride along onto the compensating row, so the quarterly summary
  nets the tax out of the same group the charge sits in. A double
  reversal is rejected — the pre-lock guard answers reads, the
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
          {:ok, [reversal | _rest]} ->
            replayed_or_conflict(reversal, opts)

          {:ok, []} ->
            post_reversal(wallet, original, opts)

          # The guard answers the sequential case; the concurrent case
          # loses to the partial unique index instead (DB round-trip,
          # not simulatable)
          # coveralls-ignore-start
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

  # A keyed caller replaying THEIR reversal gets it back; a second
  # reversal attempt (unkeyed, or a different key) is a double refund.
  defp replayed_or_conflict(reversal, opts) do
    case Keyword.get(opts, :idempotency_key) do
      keyed when is_binary(keyed) and keyed == reversal.idempotency_key -> reversal
      _other -> FluxVale.Repo.rollback(:already_reversed)
    end
  end

  defp post_reversal(wallet, original, opts) do
    reason = Keyword.get(opts, :reason, @reason_default)
    expected_reverses_id = original.id

    post_opts =
      opts
      |> Keyword.put(:reverses_id, original.id)
      |> Keyword.put(:fields, tax_fields(original))

    case PostEntry.call(wallet, opposite(original.type), abs(original.amount), reason, post_opts) do
      {:ok, %{reverses_id: reverses_id} = entry} when reverses_id == expected_reverses_id ->
        entry

      # The idempotency key belonged to a different post on this wallet —
      # acknowledging a refund with nothing behind it would be worse than
      # failing it.
      {:ok, _foreign} ->
        FluxVale.Repo.rollback(:idempotency_key_mismatch)

      # defensive: the posting only fails on a DB failure (the reversal
      # guard ran above; the unique-reversal index backstops the race) —
      # not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, reason} ->
        FluxVale.Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  # The refund carries the original's tax facts (gate 3, ADR-0029
  # Am. 3) so the summary nets the collected tax out of the same
  # country/state/rate/marker group the charge sits in. Non-tax
  # originals extract to nils — inert on the compensating row.
  defp tax_fields(original) do
    %{
      billing_country: original.billing_country,
      billing_state: original.billing_state,
      applied_rate: original.applied_rate,
      tax_cents: original.tax_cents,
      reverse_charge?: original.reverse_charge?
    }
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
