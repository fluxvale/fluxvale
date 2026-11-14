defmodule FluxVale.Infrastructure.Types.InstanceFailureReason do
  @moduledoc """
  Why an Instance is in `:error` (#179): the classification internal
  failures map to friendly user copy through. One value per writer arm
  of the lifecycle — the technical detail keeps living in
  `status_message` (admin-only reveal); this is the closed vocabulary
  the user-facing surface reads.

  Stored as text (the PlatformRole stance): adding a value is a
  code-only change, no migration.
  """

  use Ash.Type.Enum,
    values: [
      :deploy_failed,
      :stuck,
      :missing,
      :rollout_failed,
      :start_failed,
      :stop_failed,
      :restore_failed,
      :teardown_failed
    ]

  # The unintended failures a healthy workload may clear (#776) — the
  # reconciler's recovery gate and its trigger's queue filter read this
  # one list, so the two cannot drift. `nil` (legacy rows) is added by
  # the reconciler separately: SQL `IN` does not match NULL.
  @recoverable [:stuck, :missing, :rollout_failed, :start_failed]

  @doc "The failure reasons eligible for stale-error recovery (#776)."
  @spec recoverable() :: [atom()]
  def recoverable, do: @recoverable
end
