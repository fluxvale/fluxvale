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
end
