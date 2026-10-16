defmodule FluxVale.Billing.Operations.PostEntry do
  @moduledoc """
  The idempotent single-entry poster — the internal seam every posting
  operation (grant/credit/debit/reverse) routes through; the port of v1's
  `Billing.post/5`, split so each verb-named operation owns its semantics
  (defaults, direction, guards) while the replay rule lives in exactly
  one place.

  `amount` is always a magnitude in whole cents — the sign is applied from
  `type`, so a caller cannot invert a posting by passing a negative. With
  `idempotency_key: "..."`, a repeated post returns the existing entry
  unchanged; a truly concurrent duplicate loses to the
  `(wallet_id, idempotency_key)` identity and surfaces as an error — the
  correct failure mode, never a double-post. Keyless posts always insert.

  `fields:` (a map) carries extra accepted ledger attributes onto the
  created row — the charge credits' tax facts (billing country/state,
  applied rate, ADR-0029 Am. 3 gate 3). CompleteTopup is the only
  caller that passes it; every other posting stays null.

  System operation — runs with `authorize?: false` (the posting machinery;
  actors read the ledger, they never post to it).
  """

  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Types.EntryReason
  alias FluxVale.Billing.Types.EntryType
  alias FluxVale.Billing.Wallet

  require Ash.Query

  @spec call(Wallet.t(), EntryType.t(), pos_integer(), EntryReason.t(), keyword()) ::
          {:ok, LedgerEntry.t()} | {:error, term()}
  def call(%Wallet{} = wallet, type, amount, reason, opts \\ [])
      when type in [:credit, :debit] and is_integer(amount) and amount > 0 do
    idempotency_key = Keyword.get(opts, :idempotency_key)
    reverses_id = Keyword.get(opts, :reverses_id)
    fields = Keyword.get(opts, :fields) || %{}

    with :none <- existing_for_key(wallet, idempotency_key) do
      create_entry(
        wallet,
        signed_amount(type, amount),
        type,
        reason,
        idempotency_key,
        reverses_id,
        fields
      )
    end
  end

  defp signed_amount(:credit, amount), do: amount
  defp signed_amount(:debit, amount), do: -amount

  # `{:ok, entry}` on an idempotent hit, `:none` when free to post. A read
  # failure propagates rather than risking a double-post.
  defp existing_for_key(_wallet, nil), do: :none

  defp existing_for_key(%Wallet{} = wallet, key) do
    result =
      LedgerEntry
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(wallet_id == ^wallet.id and idempotency_key == ^key)
      |> Ash.Query.limit(1)
      |> Ash.read(authorize?: false)

    case result do
      {:ok, [entry | _rest]} ->
        {:ok, entry}

      {:ok, []} ->
        :none

      # defensive: DB read failure — propagates rather than risking a
      # double-post; not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  defp create_entry(wallet, amount, type, reason, key, reverses_id, fields) do
    params =
      Map.merge(
        %{
          wallet_id: wallet.id,
          amount: amount,
          type: type,
          reason: reason,
          idempotency_key: key,
          reverses_id: reverses_id
        },
        fields
      )

    result =
      LedgerEntry
      |> Ash.Changeset.for_create(:create, params)
      # return_notifications? — LedgerEntry has no notifiers, and postings
      # often run inside a caller-managed transaction (settle, reverse);
      # taking the (empty) notification list keeps those transactions from
      # warning about undelivered notifications. Revisit trigger: the
      # first notifier on the ledger.
      |> Ash.create(authorize?: false, return_notifications?: true)

    case result do
      {:ok, entry, _notifications} ->
        {:ok, entry}

      # defensive: an insert failure here is a DB failure or the
      # idempotency-identity backstop for an UNLOCKED caller (grant and
      # credit hold no lock — two concurrent same-key credits race, and
      # the loser lands here). True concurrency only: no sequential test
      # can reach it.
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end
end
