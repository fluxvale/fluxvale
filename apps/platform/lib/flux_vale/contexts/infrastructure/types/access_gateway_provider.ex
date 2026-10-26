defmodule FluxVale.Infrastructure.Types.AccessGatewayProvider do
  @moduledoc """
  Which access-provider implementation backs an `AccessGateway`
  (ADR-0039 §2): `:tailscale` is the only member today; a WireGuard
  gateway adds an atom and an implementation module, no migration.

  `:text`-stored like the other enums, so adding a value is code-only.
  """

  use Ash.Type.Enum, values: [:tailscale]
end
