defmodule FluxVale.Infrastructure.Types.InstanceExposure do
  @moduledoc """
  Instance reachability (#265, the network-isolation primitive):
  `:public` (the default — today's behavior, hostname served at the
  edge) or `:private` (no route on the public entrypoint, namespace
  ingress from the edge denied; in-cluster management keeps working).

  Provider-agnostic by decision (#265): the state names reachability,
  not any access provider — a future private-access layer (any
  WireGuard-shaped thing) attaches to `:private` without schema
  change. Enum values are `:text`-stored like `InstanceStatus`:
  adding one is code-only, no migration for the value set.
  """

  use Ash.Type.Enum, values: [:public, :private]
end
