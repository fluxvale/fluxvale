defmodule FluxVale.Infrastructure.Types.BackupRunKind do
  @moduledoc """
  How a `BackupRun` came to be (#222, ADR-0037 §3/§5):

  - `:scheduled` — the `BackupSweep` due pass opened the instance's daily
    window and started it.
  - `:manual` — the owner pressed "Back up now".
  - `:restore` — the owner restored a snapshot back into the instance
    (ADR-0037 §5). The same row carries history for both directions, so
    the panel shows one timeline.

  The first two ride the same operation (`Operations.RunInstanceBackup`)
  and differ only in the kind; restore is its own operation
  (`Operations.RestoreInstanceBackup`) with its own Job. Enum values are
  `:text`-stored, so adding one is code-only, no migration.
  """

  use Ash.Type.Enum, values: [:scheduled, :manual, :restore]
end
