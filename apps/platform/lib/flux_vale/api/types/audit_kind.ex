defmodule FluxVale.Api.Types.AuditKind do
  @moduledoc """
  What an audit row records (#360 slice 5): a `:request` made the
  boundary, a `:mint` or `:revoke` changed the token's lifecycle.
  """

  use Ash.Type.Enum, values: [:request, :mint, :revoke]
end
