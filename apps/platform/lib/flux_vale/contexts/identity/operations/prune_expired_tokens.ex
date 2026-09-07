defmodule FluxVale.Identity.Operations.PruneExpiredTokens do
  @moduledoc """
  Deletes expired rows from the revocable token store (v1's janitor
  operation, ported — #23).

  Callers are system processes with no actor (the janitor) — they pass
  `authorize?: false` explicitly, the same posture as the seeds bootstrap.
  """

  alias FluxVale.Identity.Token

  @doc """
  Deletes all token records whose `expires_at` is in the past.

  Returns `{:ok, count}` where `count` is the number of deleted rows.
  Rides the token resource's `:expired` read and `:expunge_expired`
  destroy (`AshAuthentication.TokenResource`'s built-in pair).
  """
  @spec call(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(opts \\ []) do
    opts = Keyword.put(opts, :return_records?, true)

    result =
      Token
      |> Ash.Query.for_read(:expired)
      |> Ash.bulk_destroy(:expunge_expired, %{}, opts)

    case result do
      %Ash.BulkResult{status: :success, records: records} -> {:ok, length(records)}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end
end
