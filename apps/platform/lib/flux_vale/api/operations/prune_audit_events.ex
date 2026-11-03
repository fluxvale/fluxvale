defmodule FluxVale.Api.Operations.PruneAuditEvents do
  @moduledoc """
  Sweeps audit events older than the retention horizon
  (PruneRequestWindows' shape, #360 slice 5).
  """

  alias FluxVale.Api.AuditEvent

  # 90 days: retention is a policy knob, tune on evidence — the
  # rate-limit posture. Long enough to answer "what did this token
  # do" for any support conversation; the only bound on an
  # append-per-request table.
  @retention_seconds 90 * 24 * 60 * 60

  @doc """
  Deletes all audit events older than the retention horizon.

  Returns `{:ok, count}` where `count` is the number of deleted rows.
  Callers are system processes (the janitor) — `authorize?: false`
  explicitly, the PruneExpiredTokens posture.
  """
  @spec call(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_seconds, :second)
    opts = Keyword.put(opts, :return_records?, true)

    result =
      AuditEvent
      |> Ash.Query.for_read(:stale, %{cutoff: cutoff})
      |> Ash.bulk_destroy(:expunge_stale, %{}, opts)

    case result do
      %Ash.BulkResult{status: :success, records: records} ->
        {:ok, length(records)}

      # coveralls-ignore-start - bulk failure = DB outage mid-destroy; the
      # Oban retry policy owns recovery (AGENTS: cluster-level concern)
      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
        # coveralls-ignore-stop
    end
  end
end
