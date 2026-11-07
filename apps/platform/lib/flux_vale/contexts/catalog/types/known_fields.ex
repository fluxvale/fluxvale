defmodule FluxVale.Catalog.Types.KnownFields do
  @moduledoc """
  The unknown-field refusal shared by the catalog's map-shaped custom
  types (`EnvVarSpec`, `FirstRunContract`): a cast rejects keys outside
  the type's known set and names both the unknown keys and the
  supported ones.

  Callers normalize their keys first: this guard takes the map's keys
  verbatim, so an unnormalized key is reported as unknown.
  """

  @spec reject(map(), MapSet.t()) :: :ok | {:error, String.t()}
  def reject(input, %MapSet{} = known_fields) do
    unknown = Map.keys(input) -- MapSet.to_list(known_fields)

    if unknown == [] do
      :ok
    else
      {:error,
       "unknown field(s) #{inspect(unknown)}; supported: #{inspect(Enum.sort(MapSet.to_list(known_fields)))}"}
    end
  end
end
