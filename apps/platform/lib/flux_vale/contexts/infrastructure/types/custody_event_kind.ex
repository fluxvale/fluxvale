defmodule FluxVale.Infrastructure.Types.CustodyEventKind do
  @moduledoc """
  What a custody event row records (#597 S2, the D1 amendment): a
  custody-state change (`:stored`, `:replaced`, `:revoked`) or a use
  of the held key (`:used` — paste-time verification now, client
  mint/rotate in later slices).
  """
  use Ash.Type.Enum, values: [:stored, :replaced, :revoked, :used]
end
