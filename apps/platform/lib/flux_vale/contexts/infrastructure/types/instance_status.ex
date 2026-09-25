defmodule FluxVale.Infrastructure.Types.InstanceStatus do
  @moduledoc """
  Instance lifecycle states (ADR-0005):
  `pending → deploying → starting → running ⇄ stopped`; `error` from any
  state; `deleting` from any state (async teardown, row hard-deleted on
  success).
  """

  use Ash.Type.Enum,
    values: [:pending, :deploying, :starting, :running, :stopped, :error, :deleting]
end
