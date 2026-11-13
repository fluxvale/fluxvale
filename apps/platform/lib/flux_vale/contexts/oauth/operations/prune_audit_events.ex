defmodule FluxVale.OAuth.Operations.PruneAuditEvents do
  @moduledoc """
  Sweeps OAuth audit rows past the 90-day retention horizon (#766),
  the Api.PruneAuditEvents posture.
  """

  alias FluxVale.OAuth.AuditEvent

  @retention_seconds 90 * 24 * 60 * 60

  @doc """
  Deletes OAuth audit events older than the retention horizon. Returns
  `{:ok, count}`.
  """
  @spec call(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_seconds, :second)
    query = Ash.Query.for_read(AuditEvent, :stale, %{cutoff: cutoff})

    {:ok, count} = Ash.count(query, authorize?: false)

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
