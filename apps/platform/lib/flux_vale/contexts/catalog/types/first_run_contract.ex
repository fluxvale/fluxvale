defmodule FluxVale.Catalog.Types.FirstRunContract do
  @moduledoc """
  One AppVersion's first-run contract — how an app becomes usable on
  first open (#181, ADR-0034), declared in catalog data instead of
  trusted to per-deploy form defaults:

    * `pattern` — the taxonomy atom (`first_registered_user_admin`:
      registration open on first boot, the first registrant becomes the
      admin). Adding a pattern = add the atom here and document it in
      the ADR; the field generalizes to the next catalog app.
    * `env` — the guaranteed env posture (string → string). Applied by
      `DeriveFromAppVersion` **above** every deploy-time layer; user
      values naming these keys are rejected loudly.
    * `forbidden_env` — keys that must never ship (default,
      configurable, or user env): the knobs that would break first
      open. The platform's half of the guarantee is an *absence*, held
      by lock-out, so the app's own admin-facing toggle stays durable.
    * `guidance` — owner-facing text (rendered on the instance page):
      what to do on first open, and what to close after setup.

  Like `EnvVarSpec`, casting and validation live here so seeds,
  AshAdmin, and the future API enforce one contract. In memory a
  struct; in storage (jsonb) a string-keyed map — atoms don't survive
  the round-trip, so `cast_stored/1` re-casts on every read.
  """

  use Ash.Type

  alias FluxVale.Catalog.Types.EnvVarSpec

  defstruct [:pattern, :env, :forbidden_env, :guidance]

  @type t :: %__MODULE__{
          pattern: pattern(),
          env: %{String.t() => String.t()},
          forbidden_env: [String.t()],
          guidance: String.t()
        }

  @type pattern :: :first_registered_user_admin

  @known_patterns [:first_registered_user_admin]
  @pattern_atoms Map.new(@known_patterns, &{Atom.to_string(&1), &1})
  @known_fields MapSet.new(~w(pattern env forbidden_env guidance)a)

  @impl Ash.Type
  def storage_type(_constraints), do: :map

  @impl Ash.Type
  # Nullable attribute; Ash skips nil casts, this arm is defensive
  # parity with EnvVarSchema's nil handling.
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(input, _constraints) do
    case new(input) do
      {:ok, contract} -> {:ok, contract}
      {:error, message} -> {:error, message}
    end
  end

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%__MODULE__{} = contract, _constraints), do: {:ok, dump(contract)}

  def dump_to_native(_other, _constraints), do: {:error, "expected a first-run contract"}

  # Stored values went through cast_input before being dumped, so they
  # are already structs — cast_stored only fires on reads (and on data
  # written outside Ash, which re-validates for free here).
  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(map, _constraints) when is_map(map), do: cast_input(map, [])

  def cast_stored(_other, _constraints), do: {:error, "expected a first-run contract"}

  @doc """
  Casts an input map (string keys — YAML/JSON/Admin forms — or the
  struct's own atom keys) into a validated `t:t/0`. No
  `String.to_atom/1` on input: `pattern` maps only through the fixed
  known set. Env values are strict strings — YAML booleans must quote
  (`"false"`, not `false`).
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, String.t()}
  # Structs re-validate through the map path (EnvVarSpec's stance): a
  # hand-built contract must fail like the equivalent map would.
  def new(%__MODULE__{} = contract), do: new(Map.from_struct(contract))

  def new(input) when is_map(input) do
    with {:ok, input} <- normalize_keys(input),
         :ok <- reject_unknown_fields(input),
         {:ok, pattern} <- cast_pattern(input),
         {:ok, env} <- cast_env(input),
         {:ok, forbidden_env} <- cast_forbidden_env(input),
         {:ok, guidance} <- cast_guidance(input),
         :ok <- check_env_forbidden_disjoint(env, forbidden_env) do
      {:ok,
       %__MODULE__{pattern: pattern, env: env, forbidden_env: forbidden_env, guidance: guidance}}
    end
  end

  def new(input), do: {:error, "expected a map, got: #{inspect(input)}"}

  @doc """
  Storage form — a string-keyed map (jsonb round-trip; atoms don't
  survive).
  """
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = contract) do
    %{}
    |> Map.put("pattern", Atom.to_string(contract.pattern))
    |> Map.put("env", contract.env)
    |> Map.put("forbidden_env", contract.forbidden_env)
    |> Map.put("guidance", contract.guidance)
  end

  # String → atom for known field names only; unknown names pass
  # through as strings so reject_unknown_fields/1 reports them.
  @field_atoms Map.new(@known_fields, &{Atom.to_string(&1), &1})

  defp normalize_keys(input) do
    initial = {:ok, %{}}

    Enum.reduce_while(input, initial, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, Map.get(@field_atoms, key, key), value)}}

      {key, _value}, _acc ->
        {:halt, {:error, "contract keys must be strings or atoms, got: #{inspect(key)}"}}
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

  defp cast_pattern(input) do
    case Map.fetch(input, :pattern) do
      {:ok, pattern} when is_atom(pattern) ->
        if pattern in @known_patterns,
          do: {:ok, pattern},
          else: {:error, unknown_pattern(pattern)}

      {:ok, pattern} when is_binary(pattern) ->
        case Map.fetch(@pattern_atoms, pattern) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, unknown_pattern(pattern)}
        end

      {:ok, other} ->
        {:error, "pattern must be one of #{inspect(@known_patterns)}, got: #{inspect(other)}"}

      :error ->
        {:error, "pattern is required"}
    end
  end

  defp unknown_pattern(pattern),
    do: "unknown pattern #{inspect(pattern)}; supported: #{inspect(@known_patterns)}"

  # Strict string values: env vars are strings end to end, and an
  # unquoted YAML boolean (`false` vs "false") is exactly the mistake
  # to catch at write time, naming the key.
  defp cast_env(input) do
    case Map.get(input, :env, %{}) do
      env when is_map(env) ->
        initial = {:ok, %{}}
        Enum.reduce_while(env, initial, &cast_env_entry/2)

      other ->
        {:error, "env must be a map of env-var name to quoted string, got: #{inspect(other)}"}
    end
  end

  # The reduce_while step; an invalid entry halts with the key named.
  defp cast_env_entry({name, value}, {:ok, acc}) do
    cond do
      not EnvVarSpec.valid_name?(name) ->
        {:halt, {:error, "#{inspect(name)} is not a valid env-var name (expected POSIX-shaped)"}}

      not is_binary(value) ->
        {:halt, {:error, "env #{name} must be a quoted string, got: #{inspect(value)}"}}

      true ->
        {:cont, {:ok, Map.put(acc, name, value)}}
    end
  end

  defp cast_forbidden_env(input) do
    case Map.get(input, :forbidden_env, []) do
      names when is_list(names) ->
        invalid = Enum.reject(names, &EnvVarSpec.valid_name?/1)

        if invalid == [] do
          {:ok, names}
        else
          {:error, "forbidden_env entries must be valid env-var names, got: #{inspect(invalid)}"}
        end

      other ->
        {:error, "forbidden_env must be a list of env-var names, got: #{inspect(other)}"}
    end
  end

  defp cast_guidance(input) do
    case Map.fetch(input, :guidance) do
      {:ok, guidance} when is_binary(guidance) and guidance != "" ->
        {:ok, guidance}

      {:ok, other} ->
        {:error, "guidance must be a non-empty string, got: #{inspect(other)}"}

      :error ->
        {:error, "guidance is required"}
    end
  end

  # A key cannot be both pinned and forbidden — that contract states
  # nothing checkable and the deploy-time layers couldn't honor it.
  # Case-insensitive, matching the enforcement seams (consumers fold
  # env names onto config settings; Forgejo's environment-to-ini
  # lowercases ini sections).
  defp check_env_forbidden_disjoint(env, forbidden_env) do
    folded_forbidden = Enum.map(forbidden_env, &String.downcase/1)

    overlap =
      env
      |> Map.keys()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.filter(&(&1 in folded_forbidden))

    if overlap == [] do
      :ok
    else
      {:error,
       "env and forbidden_env must not overlap (#{Enum.join(overlap, ", ")} appears in both)"}
    end
  end
end
