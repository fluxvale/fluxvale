defmodule FluxVale.Infrastructure.Types.BackupRunKind do
  @moduledoc """
  How a `BackupRun` came to be (#222, ADR-0037 §3):

  - `:scheduled` — the `BackupSweep` due pass opened the instance's daily
    window and started it.
  - `:manual` — the owner pressed "Back up now".

  Both ride the same operation (`Operations.RunInstanceBackup`); only the
  kind differs. A later slice adds `:restore` (ADR-0037 §5) — enum values
  are `:text`-stored, so that is a code-only change, no migration.
  """

  use Ash.Type.Enum, values: [:scheduled, :manual]
end
