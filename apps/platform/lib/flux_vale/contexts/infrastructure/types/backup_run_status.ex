defmodule FluxVale.Infrastructure.Types.BackupRunStatus do
  @moduledoc """
  One backup's lifecycle (#222, ADR-0037 §3):

  - `:pending` — the row exists, the k8s Job is not applied yet.
  - `:running` — the Job is applied; the sweep's watch pass owns the
    outcome from here.
  - `:succeeded` — restic reported a snapshot (id and byte counts on the
    row).
  - `:failed` — the Job failed, the instance vanished, or the run went
    stale; `error_summary` says why, sanitized.

  Terminal states never change: a failed run is history, and the next
  scheduled window (or the owner's manual retry) is the retry. Text-stored
  like the instance statuses — adding a value is code-only.
  """

  use Ash.Type.Enum, values: [:pending, :running, :succeeded, :failed]
end
