defmodule FluxVale.Identity.Operations do
  @moduledoc """
  Identity operations: token lifecycle maintenance.

  System-facing entry points for internal maintenance tasks;
  `FluxVale.Identity` exposes them as `defdelegate`s so the domain module
  stays a clean interface (v1's pattern, ported — #23). Callers are system
  processes with no actor (the janitor) — they pass `authorize?: false`
  explicitly, the same posture as the seeds bootstrap.
  """

  alias FluxVale.Identity.Token

  @doc """
  Deletes all token records whose `expires_at` is in the past.

  Returns `{:ok, count}` where `count` is the number of deleted rows.
  Rides the token resource's `:expired` read and `:expunge_expired`
  destroy (`AshAuthentication.TokenResource`'s built-in pair).
  """
  @spec prune_expired_tokens(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune_expired_tokens(opts \\ []) do
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
