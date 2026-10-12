defmodule FluxVale.Billing.Operations.ReadBalance do
  @moduledoc """
  Loads the wallet's balance — the live `sum` of its ledger (#120).
  Authorization propagates from the caller: user-facing surfaces (the
  balance UI, #123) pass the actor; system callers pass
  `authorize?: false` explicitly.
  """

  alias FluxVale.Billing.Wallet

  @spec call(Wallet.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def call(%Wallet{} = wallet, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?, true)

    # The policy runs on a fresh get — loading the aggregate on the
    # in-memory record would skip authorization entirely (a stranger
    # would read another org's balance).
    case Ash.get(Wallet, wallet.id, actor: actor, authorize?: authorize?) do
      {:ok, wallet} ->
        case Ash.load(wallet, :balance, authorize?: false) do
          {:ok, wallet} ->
            {:ok, wallet.balance || 0}

          # coveralls-ignore-start - defensive: DB read failure, not
          # simulatable under the sandbox
          {:error, _reason} = error ->
            error
            # coveralls-ignore-stop
        end

      {:error, _reason} = error ->
        error
    end
  end
end
