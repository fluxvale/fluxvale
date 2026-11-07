defmodule FluxVale.Billing.Operations.DebitWallet do
  @moduledoc """
  Posts consumption against a wallet (#120) — the flat-rate accrual's
  posting surface (#121 wires the settle call; refunds of remaining
  credits also debit).

  Takes the accrued amount in integer **micro-cents** (µ¢; 1¢ =
  10_000 µ¢) and posts **whole cents** to the ledger, pooling the
  fractional remainder into the wallet's `carryover` — sub-cent dust
  never forms per instance, it accumulates wallet-wide until the next
  debit rounds it out (ADR-0028's no-draft settlement; no stopped-instance
  floor). A debit whose whole-cent portion is zero posts no ledger row —
  `{:ok, :accrued}` — the fraction moved, the ledger didn't.

  v1's settle discipline ports: transaction-scoped advisory lock on the
  wallet FIRST, then the carryover re-read — concurrent posters serialize
  on the wallet, and each reads the winner's committed remainder, so no
  lost update can double-post or swallow a fraction.

  Keyed debits replay safe: the settle transaction checks the key FIRST
  (under the lock, before any math) and a hit returns the original entry
  with the carryover untouched — a retried post can never rewrite the
  pool, because the remainder always derives from the *current* carryover,
  not the first call's. A settle whose whole-cent portion is zero posts no
  ledger row, so its key lives nowhere — the caller owns retry safety for
  accrued debits (the settle anchors are the arbiter, #121: a committed
  settle advances the anchors, so a post-commit retry never recomputes the
  same interval). System operation, `authorize?: false`.
  """

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Operations.PostEntry
  alias FluxVale.Billing.Operations.ResolveWallet
  alias FluxVale.Billing.Wallet

  require Ash.Query

  @micro_per_cent 10_000
  @reason_default :usage

  @spec call(Wallet.t() | Organization.t(), pos_integer(), keyword()) ::
          {:ok, LedgerEntry.t() | :accrued} | {:error, term()}
  # defguard is a compile-time macro — the line never runs (cover artifact)
  # coveralls-ignore-next-line
  defguard is_positive_micros(amount) when is_integer(amount) and amount > 0

  def call(target, micro_cents, opts \\ []) when is_positive_micros(micro_cents) do
    with {:ok, wallet} <- ResolveWallet.call(target) do
      settle(wallet, micro_cents, opts)
    end
  end

  defp settle(wallet, micro_cents, opts) do
    outcome =
      FluxVale.Repo.transaction(fn ->
        # Lock FIRST, then re-read the carryover (v1's settle_pod): the
        # lock serializes concurrent posters; the re-read guarantees the
        # loser sees the winner's committed remainder instead of a stale
        # capture. Held until this transaction commits.
        FluxVale.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [wallet.id])

        case Ash.get(Wallet, wallet.id, authorize?: false) do
          {:ok, fresh} ->
            settle_fresh(fresh, micro_cents, opts)

          # coveralls-ignore-start - defensive: the wallet was resolved
          # moments ago; a delete mid-settle is not simulatable
          {:error, _reason} ->
            FluxVale.Repo.rollback(:wallet_not_found)
            # coveralls-ignore-stop
        end
      end)

    case outcome do
      {:ok, result} ->
        {:ok, result}

      # defensive: rollback only fires from the DB-failure arms below —
      # not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end

  # A keyed replay returns the original entry (unwrapped — the
  # transaction must not double-wrap it); anything else settles.
  defp settle_fresh(fresh, micro_cents, opts) do
    result =
      with :none <- already_settled?(fresh, opts) do
        total = fresh.carryover + micro_cents

        post_and_store(fresh, div(total, @micro_per_cent), rem(total, @micro_per_cent), opts)
      end

    case result do
      {:ok, entry} -> entry
      posted -> posted
    end
  end

  # Replay check, under the lock, before any math: a keyed debit that
  # already posted returns its original entry and the carryover stays
  # exactly as the first settle left it. Keyless (and accrued — row-less)
  # debits have nothing to replay against.
  defp already_settled?(%Wallet{} = wallet, opts) do
    case Keyword.get(opts, :idempotency_key) do
      nil ->
        :none

      key ->
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

          # defensive: DB read failure — the settle fails loudly rather
          # than risk a double-post; not simulatable under the sandbox
          # coveralls-ignore-start
          {:error, reason} ->
            FluxVale.Repo.rollback(reason)
            # coveralls-ignore-stop
        end
    end
  end

  defp post_and_store(%Wallet{} = wallet, cents, remainder, opts) do
    with {:ok, posted} <- post(wallet, cents, opts),
         :ok <- write_carryover(wallet, remainder) do
      posted
    else
      # defensive: the posting/carryover writes only fail on a DB
      # failure — not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, reason} ->
        FluxVale.Repo.rollback(reason)
        # coveralls-ignore-stop
    end
  end

  # Zero whole cents: no ledger row — the fraction pools in carryover.
  defp post(_wallet, 0, _opts), do: {:ok, :accrued}

  defp post(wallet, cents, opts) do
    PostEntry.call(
      wallet,
      :debit,
      cents,
      Keyword.get(opts, :reason, @reason_default),
      opts
    )
  end

  defp write_carryover(wallet, remainder) do
    result =
      wallet
      |> Ash.Changeset.for_update(:set_carryover, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:carryover, remainder)
      # return_notifications? — Wallet has no notifiers; taking the
      # (empty) notification list here keeps the settle transaction from
      # warning about undelivered notifications.
      |> Ash.update(authorize?: false, return_notifications?: true)

    case result do
      {:ok, _wallet, _notifications} ->
        :ok

      # defensive: DB write failure, not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end
end
