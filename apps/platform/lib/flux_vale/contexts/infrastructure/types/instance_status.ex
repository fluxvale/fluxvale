defmodule FluxVale.Infrastructure.Types.InstanceStatus do
  @moduledoc """
  Instance lifecycle states (ADR-0005):
  `pending → deploying → starting → running ⇄ stopped`; `sleeping` when the
  idle sweep scaled the workload away (#203, ADR-0036 — platform-initiated,
  traffic-reversible, storage-only billing); `restoring` while a snapshot is
  being written back over the volume (#222, ADR-0037 §5 — the restore owns
  the instance exclusively); `error` from any state; `deleting` from any
  state (async teardown, row hard-deleted on success); `lost` when the
  namespace vanished externally (#196) — metering parked, owner re-deploys or
  tears down. Enum values are `:text`-stored: adding one is code-only, no
  migration (the `failure_reason` stance).
  """

  use Ash.Type.Enum,
    values: [
      :pending,
      :deploying,
      :starting,
      :running,
      :sleeping,
      :restoring,
      :stopped,
      :error,
      :deleting,
      :lost
    ]
end
