defmodule FluxVale.Catalog.Types.BackingService do
  @moduledoc """
  One bundled backing service an AppVersion declares (#612, ADR-0045) —
  the metadata half; rendering is the deployer's S2:

    * `kind` — `:postgres` | `:redis` (the closed launch set; more
      engines join by registry + kind growth, a deliberate diff).
    * `version` — the MAJOR as a string (`"18"`). The platform registry
      owns exact image pins; the validator checks the major exists
      there. Shape lives here so a stored row re-reads identically
      regardless of config.
    * `url_env` — the env the platform composes the service URL into
      (`DATABASE_URL`); must exist in the version's
      `configurable_env_vars` (ValidateBackingServices, at write time).

  Like `OidcWiring`: casting and validation live here so seeds,
  AshAdmin, and the API enforce one contract. In memory a struct; in
  storage (jsonb) a string-keyed map — `kind` doesn't survive the
  round-trip as an atom, so `cast_stored/1` re-casts on every read.
  """

  use Ash.Type
  # The json_schema/1 callback below rides this behaviour — it shapes
  # the rendered OpenAPI artifact's `items` entry for this type.
  use AshJsonApi.Type

  alias FluxVale.Catalog.Types.EnvVarSpec
  alias FluxVale.Catalog.Types.KnownFields

  defstruct [:kind, :version, :url_env]

  @type t :: %__MODULE__{kind: kind(), version: String.t(), url_env: String.t()}

  @type kind :: :postgres | :redis

  @known_kinds [:postgres, :redis]
  @kind_atoms Map.new(@known_kinds, &{Atom.to_string(&1), &1})
  @known_fields MapSet.new(~w(kind version url_env)a)

  # Major only, as a string ("18"): the exact pin is platform-side
  # (registry config), so "16.4" and "v16" are shape errors here.
  @major_format ~r/^\d+$/

  @doc """
  The known kind atoms, `OidcWiring.known_kinds/0`'s stance: the admin
  edit surface derives its select from this one list, so a kind added
  here can never sit outside the select's reach.
  """
  @spec known_kinds() :: [kind()]
  def known_kinds, do: @known_kinds

  @impl Ash.Type
  def storage_type(_constraints), do: :map

  @impl Ash.Type
  def cast_input(input, _constraints) do
    case new(input) do
      {:ok, service} -> {:ok, service}
      {:error, message} -> {:error, message}
    end
  end

  @impl Ash.Type
  def dump_to_native(%__MODULE__{} = service, _constraints), do: {:ok, dump(service)}

  def dump_to_native(_other, _constraints), do: {:error, "expected a backing-service declaration"}

  # Stored values went through cast_input before being dumped, so they
  # are already structs — cast_stored only fires on reads (and on data
  # written outside Ash, which re-validates for free here).
  @impl Ash.Type
  def cast_stored(map, _constraints) when is_map(map), do: cast_input(map, [])

  def cast_stored(_other, _constraints), do: {:error, "expected a backing-service declaration"}

  @doc """
  Casts an input map (string keys — YAML/JSON/Admin forms — or the
  struct's own atom keys) into a validated `t:t/0`. No
  `String.to_atom/1` on input: `kind` maps only through the fixed
  known set; `version` is digits-only (major); `url_env` must be
  POSIX-shaped (`EnvVarSpec.valid_name?/1`). Registry membership is
  NOT checked here — a config-dependent read would break stored-row
  re-reads; `ValidateBackingServices` owns it.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, String.t()}
  # Structs re-validate through the map path (FirstRunContract's
  # stance): a hand-built declaration must fail like the equivalent map.
  def new(%__MODULE__{} = service), do: new(Map.from_struct(service))

  def new(input) when is_map(input) do
    with {:ok, input} <- normalize_keys(input),
         :ok <- KnownFields.reject(input, @known_fields),
         {:ok, kind} <- cast_kind(input),
         {:ok, version} <- cast_version(input),
         {:ok, url_env} <- cast_url_env(input) do
      {:ok, %__MODULE__{kind: kind, version: version, url_env: url_env}}
    end
  end

  def new(input), do: {:error, "expected a map, got: #{inspect(input)}"}

  @doc """
  Storage form — a string-keyed map (jsonb round-trip; atoms don't
  survive).
  """
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = service) do
    %{}
    |> Map.put("kind", Atom.to_string(service.kind))
    |> Map.put("version", service.version)
    |> Map.put("url_env", service.url_env)
  end

  # The OpenAPI artifact's item schema (#616 review): without this the
  # rendered array attribute carries `items: {}` — any JSON. The wire
  # shape is dump/1's: three fields, kind from the closed set, version
  # digits-only, exactly the fields the type enforces.
  @impl AshJsonApi.Type
  def json_schema(_constraints) do
    %{
      "type" => "object",
      "properties" => %{
        "kind" => %{
          "type" => "string",
          "enum" => Enum.map(@known_kinds, &Atom.to_string/1)
        },
        "version" => %{"type" => "string", "pattern" => "^\\d+$"},
        "url_env" => %{"type" => "string"}
      },
      "required" => ["kind", "version", "url_env"],
      "additionalProperties" => false
    }
  end

  # String → atom for known field names only; unknown names pass
  # through as strings so KnownFields.reject/2 reports them.
  @field_atoms Map.new(@known_fields, &{Atom.to_string(&1), &1})

  defp normalize_keys(input) do
    initial = {:ok, %{}}

    Enum.reduce_while(input, initial, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, Map.get(@field_atoms, key, key), value)}}

      {key, _value}, _acc ->
        {:halt, {:error, "declaration keys must be strings or atoms, got: #{inspect(key)}"}}
    end)
  end

  defp cast_kind(input) do
    case Map.fetch(input, :kind) do
      {:ok, kind} when is_atom(kind) ->
        if kind in @known_kinds,
          do: {:ok, kind},
          else: {:error, unknown_kind(kind)}

      {:ok, kind} when is_binary(kind) ->
        case Map.fetch(@kind_atoms, kind) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, unknown_kind(kind)}
        end

      {:ok, other} ->
        {:error, "kind must be one of #{inspect(@known_kinds)}, got: #{inspect(other)}"}

      :error ->
        {:error, "kind is required"}
    end
  end

  defp unknown_kind(kind),
    do: "unknown kind #{inspect(kind)}; supported: #{inspect(@known_kinds)}"

  defp cast_version(input) do
    case Map.fetch(input, :version) do
      {:ok, version} when is_binary(version) ->
        if Regex.match?(@major_format, version),
          do: {:ok, version},
          else: {:error, "version must be a major-version digit string, got: #{inspect(version)}"}

      {:ok, other} ->
        {:error, "version must be a major-version digit string, got: #{inspect(other)}"}

      :error ->
        {:error, "version is required"}
    end
  end

  defp cast_url_env(input) do
    case Map.fetch(input, :url_env) do
      {:ok, name} when is_binary(name) ->
        if EnvVarSpec.valid_name?(name),
          do: {:ok, name},
          else: {:error, "url_env is not a valid env-var name, got: #{inspect(name)}"}

      {:ok, other} ->
        {:error, "url_env must be an env-var name string, got: #{inspect(other)}"}

      :error ->
        {:error, "url_env is required"}
    end
  end
end

# Same story as OidcWiring's encoder (#362): `backing_services` is a
# public attribute on the app-version routes, rendered with Jason — the
# storage form (dump/1, `kind` as a string) is the wire form (names +
# majors only; no values exist at catalog level).
defimpl Jason.Encoder, for: FluxVale.Catalog.Types.BackingService do
  alias FluxVale.Catalog.Types.BackingService

  @impl Jason.Encoder
  def encode(service, opts) do
    service
    |> BackingService.dump()
    |> Jason.Encoder.encode(opts)
  end
end
