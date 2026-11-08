defmodule FluxVale.Catalog.Types.OidcWiring do
  @moduledoc """
  One AppVersion's OIDC wiring recipe (#597) — how the platform wires
  sign-in to an org's Pocket ID, declared in catalog data:

    * `kind` — `:env`: the platform injects everything at deploy
      (Vaultwarden). `:in_app`: mint the client and show copy-ready
      values in the app's own admin screen (Forgejo/Kavita shape, v2 —
      the type carries the union so no migration later).
    * `issuer_env` / `client_id_env` / `client_secret_env` — the env
      names the wiring writes; each must exist in the version's
      `configurable_env_vars` (enforced by
      `ValidateOidcWiringEnv` at write time, so catalog data can't
      drift from the app's declared inputs).
    * `enabled_env` — optional toggle the wiring sets true.
    * `pkce` — whether the minted Pocket ID client gets PKCE.

  Like `FirstRunContract`: casting and validation live here so seeds,
  AshAdmin, and the API enforce one contract. In memory a struct; in
  storage (jsonb) a string-keyed map — `kind` doesn't survive the
  round-trip as an atom, so `cast_stored/1` re-casts on every read.
  """

  use Ash.Type

  alias FluxVale.Catalog.Types.EnvVarSpec
  alias FluxVale.Catalog.Types.KnownFields

  defstruct [:kind, :issuer_env, :client_id_env, :client_secret_env, :enabled_env, :pkce]

  @type t :: %__MODULE__{
          kind: kind(),
          issuer_env: String.t(),
          client_id_env: String.t(),
          client_secret_env: String.t(),
          enabled_env: String.t() | nil,
          pkce: boolean()
        }

  @type kind :: :env | :in_app

  @known_kinds [:env, :in_app]
  @kind_atoms Map.new(@known_kinds, &{Atom.to_string(&1), &1})
  @known_fields MapSet.new(~w(kind issuer_env client_id_env client_secret_env enabled_env pkce)a)

  @doc """
  The known kind atoms, `FirstRunContract.known_patterns/0`'s stance:
  the admin edit surface derives its select from this one list, so a
  kind added here can never sit outside the select's reach.
  """
  @spec known_kinds() :: [kind()]
  def known_kinds, do: @known_kinds

  @impl Ash.Type
  def storage_type(_constraints), do: :map

  @impl Ash.Type
  # Nullable attribute; Ash skips nil casts, this arm is defensive
  # parity with FirstRunContract's nil handling.
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(input, _constraints) do
    case new(input) do
      {:ok, wiring} -> {:ok, wiring}
      {:error, message} -> {:error, message}
    end
  end

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%__MODULE__{} = wiring, _constraints), do: {:ok, dump(wiring)}

  def dump_to_native(_other, _constraints), do: {:error, "expected an OIDC wiring recipe"}

  # Stored values went through cast_input before being dumped, so they
  # are already structs — cast_stored only fires on reads (and on data
  # written outside Ash, which re-validates for free here).
  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(map, _constraints) when is_map(map), do: cast_input(map, [])

  def cast_stored(_other, _constraints), do: {:error, "expected an OIDC wiring recipe"}

  @doc """
  Casts an input map (string keys — YAML/JSON/Admin forms — or the
  struct's own atom keys) into a validated `t:t/0`. No
  `String.to_atom/1` on input: `kind` maps only through the fixed
  known set; env names must be POSIX-shaped (`EnvVarSpec.valid_name?/1`).
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, String.t()}
  # Structs re-validate through the map path (FirstRunContract's
  # stance): a hand-built recipe must fail like the equivalent map.
  def new(%__MODULE__{} = wiring), do: new(Map.from_struct(wiring))

  def new(input) when is_map(input) do
    with {:ok, input} <- normalize_keys(input),
         :ok <- KnownFields.reject(input, @known_fields),
         {:ok, kind} <- cast_kind(input),
         {:ok, issuer_env} <- cast_required_env(input, :issuer_env),
         {:ok, client_id_env} <- cast_required_env(input, :client_id_env),
         {:ok, client_secret_env} <- cast_required_env(input, :client_secret_env),
         {:ok, enabled_env} <- cast_optional_env(input, :enabled_env),
         {:ok, pkce} <- cast_pkce(input) do
      {:ok,
       %__MODULE__{
         kind: kind,
         issuer_env: issuer_env,
         client_id_env: client_id_env,
         client_secret_env: client_secret_env,
         enabled_env: enabled_env,
         pkce: pkce
       }}
    end
  end

  def new(input), do: {:error, "expected a map, got: #{inspect(input)}"}

  @doc """
  Storage form — a string-keyed map (jsonb round-trip; atoms don't
  survive). `enabled_env` omits when nil (`EnvVarSpec.dump/1`'s
  put_if_present stance for optional fields).
  """
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = wiring) do
    %{}
    |> Map.put("kind", Atom.to_string(wiring.kind))
    |> Map.put("issuer_env", wiring.issuer_env)
    |> Map.put("client_id_env", wiring.client_id_env)
    |> Map.put("client_secret_env", wiring.client_secret_env)
    |> put_if_present("enabled_env", wiring.enabled_env)
    |> Map.put("pkce", wiring.pkce)
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
        {:halt, {:error, "recipe keys must be strings or atoms, got: #{inspect(key)}"}}
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

  defp cast_required_env(input, field) do
    case Map.fetch(input, field) do
      {:ok, name} when is_binary(name) ->
        if EnvVarSpec.valid_name?(name),
          do: {:ok, name},
          else: {:error, "#{field} is not a valid env-var name, got: #{inspect(name)}"}

      {:ok, other} ->
        {:error, "#{field} must be an env-var name string, got: #{inspect(other)}"}

      :error ->
        {:error, "#{field} is required"}
    end
  end

  # A present value validates exactly like a required one (string +
  # name shape); only absence is optional.
  defp cast_optional_env(input, field) do
    case Map.fetch(input, field) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, _present} -> cast_required_env(input, field)
    end
  end

  defp cast_pkce(input) do
    case Map.fetch(input, :pkce) do
      {:ok, pkce} when is_boolean(pkce) -> {:ok, pkce}
      {:ok, other} -> {:error, "pkce must be a boolean, got: #{inspect(other)}"}
      :error -> {:error, "pkce is required"}
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end

# Same story as FirstRunContract's encoder (#362): `oidc_wiring` is a
# public attribute on the app-version routes, rendered with Jason — the
# storage form (dump/1, `kind` as a string) is the wire form.
defimpl Jason.Encoder, for: FluxVale.Catalog.Types.OidcWiring do
  alias FluxVale.Catalog.Types.OidcWiring

  @impl Jason.Encoder
  def encode(wiring, opts) do
    wiring
    |> OidcWiring.dump()
    |> Jason.Encoder.encode(opts)
  end
end
