defmodule FluxVale.Catalog.Types.EnvVarSchema do
  @moduledoc """
  The Ash type of `AppVersion.configurable_env_vars` — a map from env-var
  name to `EnvVarSpec` (#70).

  Custom type because `:map`'s `fields:` constraint only fits fixed keys;
  env-var names are arbitrary. In memory: `%{name => %EnvVarSpec{}}`.
  In storage (jsonb): `%{name => string-keyed map}` — atoms and structs
  don't survive the round-trip, so `cast_stored/1` re-casts through
  `EnvVarSpec.new/1` on every read.

  Deploy-time input validation (a user's env values against this schema)
  lands with Instance creation (#73).
  """

  use Ash.Type

  alias FluxVale.Catalog.Types.EnvVarSpec

  @impl Ash.Type
  def storage_type(_constraints), do: :map

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, %{}}

  def cast_input(map, _constraints) when is_map(map) do
    initial = {:ok, %{}}

    Enum.reduce_while(map, initial, fn {name, spec}, {:ok, acc} ->
      cast_entry(name, spec, acc)
    end)
  end

  def cast_input(_other, _constraints), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, %{}}

  def dump_to_native(map, _constraints) when is_map(map) do
    {:ok, Map.new(map, fn {name, spec} -> {name, EnvVarSpec.dump(spec)} end)}
  end

  def dump_to_native(_other, _constraints), do: :error

  # Stored values went through cast_input before being dumped, so they are
  # already EnvVarSpec structs — cast_stored only fires on reads (and on
  # data written outside Ash, which re-validates for free here).
  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, %{}}

  def cast_stored(map, _constraints) when is_map(map), do: cast_input(map, [])

  def cast_stored(_other, _constraints), do: :error

  defp cast_entry(name, spec, acc) do
    if EnvVarSpec.valid_name?(name) do
      case EnvVarSpec.new(spec) do
        {:ok, cast} ->
          {:cont, {:ok, Map.put(acc, name, cast)}}

        {:error, message} ->
          {:halt, {:error, "#{name}: #{message}"}}
      end
    else
      {:halt, {:error, "#{inspect(name)} is not a valid env-var name (expected POSIX-shaped)"}}
    end
  end
end
