defmodule FluxVale.Infrastructure.Operations.EnvPatch do
  @moduledoc """
  The pure half of the in-place instance env update (#731 T1,
  ADR-0052): normalize/validate a `set` + `remove` patch, compute the
  platform-owned key set, merge it over the row's env, and diff the key
  names for the audit log.

  Decisions this module owns:

  - keys are POSIX-shaped (`EnvVarSpec.valid_name?/1`) and values are
    strings — the k8s Secret's contract;
  - `set`/`remove` overlap refuses (the merge would be ambiguous);
  - platform-owned keys (the version's OIDC recipe keys when a wiring
    row exists, the instance's backing-service `url_env` keys, and the
    version's `instance_url_env`) refuse a `set` with their names, and
    skip a `remove` — the platform keeps its key, the request
    succeeds, and a Terraform apply that no longer names it converges;
  - `host_allowlist_env` is NOT owned: the deployer appends the
    platform hostname to the user's value, and the patch path
    re-applies the same append (`InstanceEnvDerived.allowlist_entry/3`).

  Values appear in the returned merged map and `set` only; the caller
  logs the key names, never the values.
  """

  alias FluxVale.Catalog.Types.EnvVarSpec

  @type plan :: %{
          set: %{String.t() => String.t()},
          remove: [String.t()],
          skipped: [String.t()],
          merged: %{String.t() => String.t()},
          added: [String.t()],
          changed: [String.t()],
          removed: [String.t()]
        }

  @type error ::
          {:invalid_set, term()}
          | {:invalid_remove, term()}
          | {:invalid_name, [String.t()]}
          | {:invalid_value, [String.t()]}
          | {:overlap, [String.t()]}
          | {:owned, [String.t()]}

  @doc """
  The platform-owned env names for `instance`'s `app_version`:
  the OIDC recipe keys when a wiring row exists (`wired?`), every
  backing-service `url_env` from the instance's snapshot, and the
  version's `instance_url_env`.
  """
  @spec owned_keys(map(), map(), boolean()) :: MapSet.t(String.t())
  def owned_keys(instance, app_version, wired?) do
    sso = if wired?, do: oidc_keys(app_version.oidc_wiring), else: []

    backing = Enum.map(instance.backing_services, & &1.url_env)

    instance_url = List.wrap(app_version.instance_url_env)

    (sso ++ backing ++ instance_url)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc """
  Builds the apply plan. `current_env` is the row's env under the
  action's `FOR UPDATE` lock; `owned_keys` is `owned_keys/3`'s result.
  """
  @spec plan(map(), map() | nil, [String.t()] | nil, MapSet.t(String.t()) | [String.t()]) ::
          {:ok, plan()} | {:error, error()}
  def plan(current_env, set, remove, owned_keys) do
    with {:ok, set} <- normalize_set(set),
         {:ok, remove} <- normalize_remove(remove),
         :ok <- reject_overlap(set, remove),
         :ok <- reject_owned(set, owned_keys) do
      owned = MapSet.new(owned_keys)

      skipped =
        remove
        |> Enum.filter(&MapSet.member?(owned, &1))
        |> Enum.sort()

      applied_remove = remove -- skipped

      merged =
        current_env
        |> Map.merge(set)
        |> Map.drop(applied_remove)

      {:ok,
       %{
         set: set,
         remove: applied_remove,
         skipped: skipped,
         merged: merged,
         added: added(current_env, set),
         changed: changed(current_env, set),
         removed: removed(current_env, applied_remove)
       }}
    end
  end

  @doc """
  The honest 400 copy for a `plan/4` refusal. Owned keys name the key
  names; values never enter the message.
  """
  @spec message(error()) :: String.t()
  def message({:owned, names}) do
    "these env vars are managed by the platform and cannot be set: #{Enum.join(names, ", ")}"
  end

  def message({:overlap, names}) do
    "env vars cannot be both set and removed: #{Enum.join(names, ", ")}"
  end

  def message({:invalid_name, names}) do
    "env var names must be POSIX-shaped (letters, digits, underscores; not starting with a digit): " <>
      Enum.join(names, ", ")
  end

  def message({:invalid_value, names}) do
    "env var values must be strings: #{Enum.join(names, ", ")}"
  end

  def message({:invalid_set, _value}) do
    "set must be an object of env var names to string values"
  end

  def message({:invalid_remove, _value}) do
    "remove must be an array of env var names"
  end

  # Nil is the wire's "absent": no keys to set.
  defp normalize_set(nil), do: {:ok, %{}}

  defp normalize_set(set) when is_map(set) do
    names = Map.keys(set)

    invalid_names =
      names
      |> Enum.filter(&(not EnvVarSpec.valid_name?(&1)))
      |> Enum.sort()

    invalid_values = Enum.filter(set, fn {_key, value} -> not is_binary(value) end)

    cond do
      invalid_names != [] ->
        {:error, {:invalid_name, invalid_names}}

      invalid_values != [] ->
        invalid_keys =
          invalid_values
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        {:error, {:invalid_value, invalid_keys}}

      true ->
        {:ok, set}
    end
  end

  defp normalize_set(other), do: {:error, {:invalid_set, other}}

  # Nil is the wire's "absent": no keys to remove. Duplicates are one
  # removal (the merge is idempotent; the log should not repeat a name).
  defp normalize_remove(nil), do: {:ok, []}

  defp normalize_remove(remove) when is_list(remove) do
    invalid =
      remove
      |> Enum.filter(&(not EnvVarSpec.valid_name?(&1)))
      |> Enum.sort()

    if invalid == [] do
      {:ok, Enum.uniq(remove)}
    else
      {:error, {:invalid_name, invalid}}
    end
  end

  defp normalize_remove(other), do: {:error, {:invalid_remove, other}}

  defp reject_overlap(set, remove) do
    overlap = Enum.filter(remove, &Map.has_key?(set, &1))
    if overlap == [], do: :ok, else: {:error, {:overlap, overlap}}
  end

  defp reject_owned(set, owned_keys) do
    owned = MapSet.new(owned_keys)

    refused =
      set
      |> Map.keys()
      |> Enum.filter(&MapSet.member?(owned, &1))

    if refused == [], do: :ok, else: {:error, {:owned, refused}}
  end

  defp removed(current_env, applied_remove) do
    applied_remove
    |> Enum.filter(&Map.has_key?(current_env, &1))
    |> Enum.sort()
  end

  defp added(current_env, set) do
    set
    |> Map.keys()
    |> Enum.filter(&(not Map.has_key?(current_env, &1)))
    |> Enum.sort()
  end

  defp changed(current_env, set) do
    set
    |> Map.keys()
    |> Enum.filter(fn key ->
      Map.has_key?(current_env, key) and Map.get(current_env, key) != Map.get(set, key)
    end)
    |> Enum.sort()
  end

  defp oidc_keys(nil), do: []

  defp oidc_keys(wiring) do
    [wiring.issuer_env, wiring.client_id_env, wiring.client_secret_env, wiring.enabled_env]
  end
end
