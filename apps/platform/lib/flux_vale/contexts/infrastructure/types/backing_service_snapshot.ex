defmodule FluxVale.Infrastructure.Types.BackingServiceSnapshot do
  @moduledoc """
  One bundled backing service as the **Instance** pins it (#612,
  ADR-0045) — the render-ready half of `Catalog.Types.BackingService`
  (which is the version's *declaration*). `DeriveFromAppVersion`
  resolves the declaration against the platform registry at create and
  force-writes these; the deployer and the resize read only the row:

    * `kind` — `:postgres` | `:redis` (the declaration's closed set).
    * `version` — the declared MAJOR, kept so a future upgrade op can
      see what the instance runs without parsing the image ref.
    * `image` — the registry's exact pin resolved at CREATE (D2): a
      registry bump, or a dropped major, can never re-spec a live
      instance — not on redeploy, not on resize.
    * `port` / `cpu` / `memory_mb` — the per-kind render constants
      frozen with the image; `cpu` a Decimal-parseable STRING (the
      quota math's own rule — `Decimal.new/1`, never a float).
    * `url_env` — the env the deploy composes the service URL into.

  Like the catalog type: casting and validation live here, and in
  storage (jsonb) a string-keyed map — `cast_stored/1` re-casts on
  every read. System-written only (the derive); no action accepts it.
  """

  use Ash.Type

  alias FluxVale.Catalog.Types.EnvVarSpec
  alias FluxVale.Catalog.Types.KnownFields

  defstruct [:kind, :version, :image, :port, :url_env, :cpu, :memory_mb]

  @type t :: %__MODULE__{
          kind: kind(),
          version: String.t(),
          image: String.t(),
          port: pos_integer(),
          url_env: String.t(),
          cpu: String.t(),
          memory_mb: pos_integer()
        }

  @type kind :: :postgres | :redis

  @kinds [:postgres, :redis]
  @kind_atoms Map.new(@kinds, &{Atom.to_string(&1), &1})
  @known_fields MapSet.new(~w(kind version image port url_env cpu memory_mb)a)
  @major_format ~r/^\d+$/

  @impl Ash.Type
  def storage_type(_constraints), do: :map

  @impl Ash.Type
  def cast_input(input, _constraints) do
    case new(input) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, message} -> {:error, message}
    end
  end

  @impl Ash.Type
  def dump_to_native(%__MODULE__{} = snapshot, _constraints), do: {:ok, dump(snapshot)}

  def dump_to_native(_other, _constraints), do: {:error, "expected a backing-service snapshot"}

  # Writes went through cast_input (the derive), so stored maps
  # re-validate for free here — the catalog type's stance.
  @impl Ash.Type
  def cast_stored(map, _constraints) when is_map(map), do: cast_input(map, [])

  def cast_stored(_other, _constraints), do: {:error, "expected a backing-service snapshot"}

  @doc """
  Casts an input map (string keys — the jsonb round-trip — or the
  struct's own atom keys) into a validated `t:t/0`. No
  `String.to_atom/1` on input: `kind` maps only through the fixed
  known set. `cpu` must parse as a positive Decimal — the carve
  subtracts it from the purchased allocation, so a garbage string
  fails here, not mid-deploy.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, String.t()}
  # Structs re-validate through the map path — a hand-built snapshot
  # must fail like the equivalent map (the catalog type's stance).
  def new(%__MODULE__{} = snapshot), do: new(Map.from_struct(snapshot))

  def new(input) when is_map(input) do
    with {:ok, input} <- normalize_keys(input),
         :ok <- KnownFields.reject(input, @known_fields),
         {:ok, kind} <- cast_kind(input),
         {:ok, version} <- cast_version(input),
         {:ok, image} <- cast_image(input),
         {:ok, port} <- cast_port(input),
         {:ok, url_env} <- cast_url_env(input),
         {:ok, cpu} <- cast_cpu(input),
         {:ok, memory_mb} <- cast_memory(input) do
      {:ok,
       %__MODULE__{
         kind: kind,
         version: version,
         image: image,
         port: port,
         url_env: url_env,
         cpu: cpu,
         memory_mb: memory_mb
       }}
    end
  end

  def new(input), do: {:error, "expected a map, got: #{inspect(input)}"}

  @doc """
  Storage form — a string-keyed map (jsonb round-trip; atoms don't
  survive).
  """
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = snapshot) do
    %{}
    |> Map.put("kind", Atom.to_string(snapshot.kind))
    |> Map.put("version", snapshot.version)
    |> Map.put("image", snapshot.image)
    |> Map.put("port", snapshot.port)
    |> Map.put("url_env", snapshot.url_env)
    |> Map.put("cpu", snapshot.cpu)
    |> Map.put("memory_mb", snapshot.memory_mb)
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
        {:halt, {:error, "snapshot keys must be strings or atoms, got: #{inspect(key)}"}}
    end)
  end

  defp cast_kind(input) do
    case Map.fetch(input, :kind) do
      {:ok, kind} when is_atom(kind) ->
        if kind in @kinds,
          do: {:ok, kind},
          else: {:error, "unknown kind #{inspect(kind)}; supported: #{inspect(@kinds)}"}

      {:ok, kind} when is_binary(kind) ->
        case Map.fetch(@kind_atoms, kind) do
          {:ok, atom} -> {:ok, atom}
          :error -> {:error, "unknown kind #{inspect(kind)}; supported: #{inspect(@kinds)}"}
        end

      {:ok, other} ->
        {:error, "kind must be one of #{inspect(@kinds)}, got: #{inspect(other)}"}

      :error ->
        {:error, "kind is required"}
    end
  end

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

  defp cast_image(input) do
    case Map.fetch(input, :image) do
      {:ok, image} when is_binary(image) and image != "" ->
        {:ok, image}

      {:ok, other} ->
        {:error, "image must be a non-empty image-ref string, got: #{inspect(other)}"}

      :error ->
        {:error, "image is required"}
    end
  end

  defp cast_port(input) do
    case Map.fetch(input, :port) do
      {:ok, port} when is_integer(port) and port > 0 ->
        {:ok, port}

      {:ok, other} ->
        {:error, "port must be a positive integer, got: #{inspect(other)}"}

      :error ->
        {:error, "port is required"}
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

  # The registry's shape: cpu as a string ("0.10"), parsed here so the
  # carve's Decimal.new can never crash mid-render.
  defp cast_cpu(input) do
    case Map.fetch(input, :cpu) do
      {:ok, cpu} when is_binary(cpu) ->
        positive_decimal_string(cpu)

      {:ok, other} ->
        {:error, "cpu must be a positive decimal string, got: #{inspect(other)}"}

      :error ->
        {:error, "cpu is required"}
    end
  end

  defp positive_decimal_string(cpu) do
    case Decimal.parse(cpu) do
      {%Decimal{} = value, ""} ->
        if Decimal.gt?(value, 0),
          do: {:ok, cpu},
          else: {:error, "cpu must be a positive decimal string, got: #{inspect(cpu)}"}

      _unparseable ->
        {:error, "cpu must be a positive decimal string, got: #{inspect(cpu)}"}
    end
  end

  defp cast_memory(input) do
    case Map.fetch(input, :memory_mb) do
      {:ok, memory_mb} when is_integer(memory_mb) and memory_mb > 0 ->
        {:ok, memory_mb}

      {:ok, other} ->
        {:error, "memory_mb must be a positive integer, got: #{inspect(other)}"}

      :error ->
        {:error, "memory_mb is required"}
    end
  end
end
