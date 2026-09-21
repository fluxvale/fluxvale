defmodule FluxVale.Catalog.Types.EnvVarSpec do
  @moduledoc """
  One deploy-time env variable's spec — what a user may set on an AppVersion
  (#70). The in-memory shape of every `configurable_env_vars` value; casting
  and validation live here so seeds, AshAdmin, and the future API all enforce
  the same contract (v1 validated only at YAML load).

  `type` is an atom in memory, a string in storage (jsonb round-trip);
  `default` must match `type`. Unknown fields are rejected — a typo'd
  `labl` fails loudly instead of silently dropping a form field (#74 will
  render these).
  """

  defstruct [:label, :description, :type, :default, required: false, secret: false]

  @type t :: %__MODULE__{
          label: String.t(),
          description: String.t() | nil,
          type: :string | :integer | :boolean,
          required: boolean(),
          default: term() | nil,
          secret: boolean()
        }

  @known_types ~w(string integer boolean)a
  @known_fields MapSet.new(~w(label description type required default secret)a)
  @type_atoms Map.new(@known_types, &{Atom.to_string(&1), &1})

  @env_name_format ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Env-var names the schema map may be keyed by (POSIX-shaped).
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@env_name_format, name)
  def valid_name?(_other), do: false

  @doc """
  Casts an input map (string keys — YAML/JSON/Admin forms — or the struct's
  own atom keys) into a validated `t:t/0`. No `String.to_atom/1` on input:
  field names and types map only through the fixed known sets.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = spec), do: {:ok, spec}

  def new(input) when is_map(input) do
    input = normalize_keys(input)

    with :ok <- reject_unknown_fields(input),
         {:ok, label} <- cast_label(input),
         {:ok, description} <- cast_description(input),
         {:ok, type} <- cast_type(input),
         :ok <- check_default(input, type),
         :ok <- check_boolean(input, :required),
         :ok <- check_boolean(input, :secret) do
      {:ok,
       %__MODULE__{
         label: label,
         description: description,
         type: type,
         required: Map.get(input, :required, false),
         default: Map.get(input, :default),
         secret: Map.get(input, :secret, false)
       }}
    end
  end

  def new(input), do: {:error, "expected a map, got: #{inspect(input)}"}

  @doc """
  Storage form — a string-keyed map (jsonb round-trip; atoms don't survive).
  """
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = spec) do
    %{}
    |> Map.put("label", spec.label)
    |> put_if_present("description", spec.description)
    |> Map.put("type", Atom.to_string(spec.type))
    |> put_if_present("default", spec.default)
    |> Map.put("required", spec.required)
    |> Map.put("secret", spec.secret)
  end

  # String → atom for known field names only; unknown names pass through
  # as strings so reject_unknown_fields/1 reports them (no String.to_atom/1
  # on arbitrary input).
  @field_atoms Map.new(@known_fields, &{Atom.to_string(&1), &1})

  defp normalize_keys(input) do
    Map.new(input, fn
      {key, value} when is_atom(key) ->
        {key, value}

      {key, value} when is_binary(key) ->
        {Map.get(@field_atoms, key, key), value}

      {key, _value} ->
        raise ArgumentError, "env var spec key must be a string or atom, got: #{inspect(key)}"
    end)
  end

  defp reject_unknown_fields(input) do
    unknown = Map.keys(input) -- MapSet.to_list(@known_fields)

    if unknown == [] do
      :ok
    else
      {:error,
       "unknown field(s) #{inspect(unknown)}; supported: #{inspect(Enum.sort(MapSet.to_list(@known_fields)))}"}
    end
  end

  defp cast_label(input) do
    case Map.fetch(input, :label) do
      {:ok, label} when is_binary(label) and label != "" ->
        {:ok, label}

      {:ok, other} ->
        {:error, "label must be a non-empty string, got: #{inspect(other)}"}

      :error ->
        {:error, "label is required"}
    end
  end

  defp cast_description(input) do
    case Map.fetch(input, :description) do
      {:ok, nil} -> {:ok, nil}
      {:ok, description} when is_binary(description) -> {:ok, description}
      {:ok, other} -> {:error, "description must be a string, got: #{inspect(other)}"}
      :error -> {:ok, nil}
    end
  end

  defp cast_type(input) do
    case Map.fetch(input, :type) do
      {:ok, type} when is_atom(type) ->
        if type in @known_types, do: {:ok, type}, else: {:error, unknown_type(type)}

      {:ok, type} when is_binary(type) ->
        case Map.fetch(@type_atoms, type) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, unknown_type(type)}
        end

      {:ok, other} ->
        {:error, "type must be one of #{inspect(@known_types)}, got: #{inspect(other)}"}

      :error ->
        {:error, "type is required"}
    end
  end

  defp unknown_type(type),
    do: "unknown type #{inspect(type)}; supported: #{inspect(@known_types)}"

  defp check_default(input, type) do
    case Map.fetch(input, :default) do
      {:ok, nil} ->
        :ok

      {:ok, default} ->
        if default_matches_type?(default, type) do
          :ok
        else
          {:error, "default #{inspect(default)} does not match type #{inspect(type)}"}
        end

      :error ->
        :ok
    end
  end

  defp default_matches_type?(default, :string) when is_binary(default), do: true
  defp default_matches_type?(default, :integer) when is_integer(default), do: true
  defp default_matches_type?(default, :boolean) when is_boolean(default), do: true
  defp default_matches_type?(_default, _type), do: false

  defp check_boolean(input, field) do
    case Map.fetch(input, field) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, other} -> {:error, "#{field} must be a boolean, got: #{inspect(other)}"}
      :error -> :ok
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
