defmodule FluxVale.Api.Operations.PruneAuditEvents do
  @moduledoc """
  Sweeps audit events older than the retention horizon
  (PruneRequestWindows' shape, #360 slice 5).

  Count-then-destroy on purpose, not the sibling's
  `return_records?: true`: one row exists per PAT-authenticated call,
  so a backlog sweep (fresh rollout, paused cron) would otherwise
  materialize every deleted row in the janitor. The count is a
  scalar; the destroy returns no records. Exact under the janitor's
  single-writer queue (concurrency 1).
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
    query = Ash.Query.for_read(AuditEvent, :stale, %{cutoff: cutoff})

    # A count failure is a DB outage mid-sweep — crash the job and let
    # Oban's retry own recovery (the janitor is the only writer).
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
