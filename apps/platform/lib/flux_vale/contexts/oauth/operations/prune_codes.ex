defmodule FluxVale.OAuth.Operations.PruneCodes do
  @moduledoc """
  Sweeps authorization codes past their retention horizon (#766):
  expired for more than a day. Count-then-destroy, the
  PruneAuditEvents posture (the janitor is the only writer).
  """

  alias FluxVale.OAuth.AuthorizationCode

  @retention_seconds 24 * 60 * 60

  @doc """
  Deletes codes that expired before the retention horizon. Returns
  `{:ok, count}`.
  """
  @spec call(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_seconds, :second)
    query = Ash.Query.for_read(AuthorizationCode, :stale, %{cutoff: cutoff})

    {:ok, count} = Ash.count(query, Keyword.take(opts, [:actor, :authorize?]))

    result =
      Ash.bulk_destroy(query, :expunge_stale, %{}, Keyword.put(opts, :return_records?, false))

    case result do
      %Ash.BulkResult{status: :success} ->
        {:ok, count}

      # coveralls-ignore-start - bulk failure = DB outage mid-destroy; the
      # Oban retry policy owns recovery (AGENTS: cluster-level concern)
      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
        # coveralls-ignore-stop
    end
  end
end
