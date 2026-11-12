defmodule FluxVale.Infrastructure.Operations.EnvPatch do
  @moduledoc """
  The pure half of the in-place instance env update (#731 T1,
  ADR-0052): normalize/validate a `set` + `remove` patch, compute the
  platform-owned key sets, merge it over the row's env, and diff the key
  names for the audit log.

  Decisions this module owns:

  - `set` keys are POSIX-shaped (`EnvVarSpec.valid_name?/1`) and values
    are strings — the k8s Secret's contract; `remove` needs only a
    string (a stored key the create path accepted need not be
    POSIX-shaped);
  - `set`/`remove` overlap refuses (the merge would be ambiguous);
  - the deployer-composed keys (the version's OIDC recipe keys when a
    wiring row exists, the instance's backing-service `url_env` keys,
    and the version's `instance_url_env`) refuse a `set` with their
    names and skip a `remove` — the platform keeps its key, the request
    succeeds, and a Terraform apply that no longer names it converges.
    OIDC recipe keys and `instance_url_env` match EXACT-case (a user's
    `root_url` is a distinct k8s key from the platform's `ROOT_URL`);
    backing-service `url_env` keys FOLD, mirroring the create path's
    conservative superset (`DeriveFromAppVersion.backing_conflicts/2`);
  - the first-run contract's `env` keys are FIXED: both a `set` and a
    `remove` refuse, naming the keys (the contract lands at create and
    is never re-composed, so a removal would silently drop a guaranteed
    first-run value);
  - the contract's `forbidden_env` keys are NEVER SETTABLE: a `set`
    refuses; a `remove` is a legitimate cleanup (the platform never
    composes them);
  - contract matching is CASE-INSENSITIVE — the create path folds
    both lists (`DeriveFromAppVersion.contract_conflicts/2`), so a
    lowercase spelling is the same contract key;
  - `host_allowlist_env` is NOT owned: the deployer appends the
    platform hostname to the user's value, and the patch path
    composes the same append for the live Secret only
    (`InstanceEnvDerived.allowlist_entry/3`).

  Values appear in the returned merged map and `set` only; the caller
  logs the key names, never the values.
  """

  alias FluxVale.Catalog.Types.EnvVarSpec

  @type owned :: %{exact: MapSet.t(String.t()), folded: MapSet.t(String.t())}

  @type plan :: %{
          set: %{String.t() => String.t()},
          remove: [String.t()],
          skipped: [String.t()],
          composed: [String.t()],
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
          | {:fixed, [String.t()]}
          | {:forbidden, [String.t()]}

  @doc """
  The deployer-composed env names for `instance`'s `app_version`: the
  OIDC recipe keys when a wiring row exists (`wired?`), every
  backing-service `url_env` from the instance's snapshot, and the
  version's `instance_url_env`. A set of one refuses; a remove skips
  (the platform composes it above the row).

  `exact` holds the OIDC recipe keys and `instance_url_env`;
  `folded` holds the downcased backing-service `url_env` names (the
  create path's conservative superset). The first-run contract is its
  own category, not this set: `fixed_keys/1` and `forbidden_keys/1`
  carry its rules.
  """
  @spec owned_keys(map(), map(), boolean()) :: owned()
  def owned_keys(instance, app_version, wired?) do
    sso = if wired?, do: oidc_keys(app_version.oidc_wiring), else: []

    instance_url = List.wrap(app_version.instance_url_env)

    exact =
      (sso ++ instance_url)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    folded =
      instance.backing_services
      |> Enum.map(& &1.url_env)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    %{exact: exact, folded: folded}
  end

  @doc """
  The first-run contract's `env` keys — fixed at create, so both a set
  and a remove refuse.
  """
  @spec fixed_keys(map() | nil) :: MapSet.t(String.t())
  def fixed_keys(nil), do: MapSet.new()

  def fixed_keys(contract) do
    contract.env
    |> Map.keys()
    |> MapSet.new()
  end

  @doc """
  The first-run contract's `forbidden_env` keys — never settable, but a
  remove is a legitimate cleanup (the platform does not compose them).
  """
  @spec forbidden_keys(map() | nil) :: MapSet.t(String.t())
  def forbidden_keys(nil), do: MapSet.new()
  def forbidden_keys(contract), do: MapSet.new(contract.forbidden_env)

  @doc """
  Builds the apply plan. `current_env` is the row's env under the
  action's `FOR UPDATE` lock; `owned_keys`, `fixed_keys`, and
  `forbidden_keys` are the results of the functions above.
  """
  @spec plan(
          map(),
          map() | nil,
          [String.t()] | nil,
          owned(),
          MapSet.t(String.t()) | [String.t()],
          MapSet.t(String.t()) | [String.t()]
        ) ::
          {:ok, plan()} | {:error, error()}
  def plan(current_env, set, remove, owned_keys, fixed_keys, forbidden_keys) do
    with {:ok, set} <- normalize_set(set),
         {:ok, remove} <- normalize_remove(remove),
         :ok <- reject_overlap(set, remove),
         fixed = folded(fixed_keys),
         forbidden = folded(forbidden_keys),
         :ok <- reject_fixed(set, fixed),
         :ok <- reject_fixed_remove(remove, fixed),
         :ok <- reject_forbidden(set, forbidden),
         :ok <- reject_owned(set, owned_keys) do
      skipped =
        remove
        |> Enum.filter(&owned_key?(owned_keys, &1))
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
         composed: [],
         merged: merged,
         added: added(current_env, set),
         changed: changed(current_env, set),
         removed: removed(current_env, applied_remove)
       }}
    end
  end

  @doc """
  The honest 400 copy for a `plan/6` refusal. Key names only; values
  never enter the message.
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

  def message({:fixed, names}) do
    "these env vars are fixed by the app's first-run contract and cannot be changed: " <>
      Enum.join(names, ", ")
  end

  def message({:forbidden, names}) do
    "these env vars are forbidden by the app's first-run contract: " <> Enum.join(names, ", ")
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
  # Only a string is required — a stored key the create path accepted
  # may predate (or sit outside) the POSIX shape, and a removal must
  # still be able to drop it.
  defp normalize_remove(nil), do: {:ok, []}

  defp normalize_remove(remove) when is_list(remove) do
    if Enum.all?(remove, &is_binary/1) do
      {:ok, Enum.uniq(remove)}
    else
      {:error, {:invalid_remove, remove}}
    end
  end

  defp normalize_remove(other), do: {:error, {:invalid_remove, other}}

  defp reject_overlap(set, remove) do
    overlap = Enum.filter(remove, &Map.has_key?(set, &1))
    if overlap == [], do: :ok, else: {:error, {:overlap, overlap}}
  end

  defp reject_owned(set, owned) do
    refused =
      set
      |> Map.keys()
      |> Enum.filter(&owned_key?(owned, &1))

    if refused == [], do: :ok, else: {:error, {:owned, refused}}
  end

  defp reject_fixed(set, fixed) do
    refused =
      set
      |> Map.keys()
      |> Enum.filter(&folded_member?(fixed, &1))

    if refused == [], do: :ok, else: {:error, {:fixed, refused}}
  end

  defp reject_fixed_remove(remove, fixed) do
    refused = Enum.filter(remove, &folded_member?(fixed, &1))

    if refused == [], do: :ok, else: {:error, {:fixed, refused}}
  end

  defp reject_forbidden(set, forbidden) do
    refused =
      set
      |> Map.keys()
      |> Enum.filter(&folded_member?(forbidden, &1))

    if refused == [], do: :ok, else: {:error, {:forbidden, refused}}
  end

  defp folded(keys) do
    keys
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp owned_key?(%{exact: exact, folded: folded}, key) do
    MapSet.member?(exact, key) or MapSet.member?(folded, String.downcase(key))
  end

  defp folded_member?(folded_keys, key), do: MapSet.member?(folded_keys, String.downcase(key))

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
