defmodule FluxVale.Infrastructure.Instance.ValidateEnvVars do
  @moduledoc """
  Validates the merged `env_vars` map on create (defaults under user
  values, post-`DeriveFromAppVersion`):

  - keys and values are strings — K8s Secrets require it
  - values the AppVersion's `configurable_env_vars` schema declares parse
    as their declared type (`EnvVarSpec` is recast to structs on read, so
    types are atoms here)

  Only schema-declared fields are type-checked; unknown keys pass through
  (v1 stance, kept: operator-owned env outside the configurable surface).

  Validated once, at create, against the version row as it stands
  then — a point-in-time read like `DeriveFromAppVersion`'s (which
  reads the row separately, both unlocked); nothing re-checks stored
  values against a later schema. Deliberate (#605): the blueprint is
  snapshotted at create, there is no invariant to protect, so no lock
  is taken.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Resource.Validation
  alias FluxVale.Catalog.AppVersion

  @impl Validation
  def init(_opts), do: {:ok, []}

  @impl Validation
  def validate(changeset, _opts, _context) do
    env_vars = Ash.Changeset.get_attribute(changeset, :env_vars) || %{}
    schema = schema_for(Ash.Changeset.get_attribute(changeset, :app_version_id))

    check(env_vars, schema)
  end

  @doc """
  Validates an env map against a version's `configurable_env_vars`
  schema — the create validation's body, callable without a changeset
  so the in-place patch path (#731, ADR-0052 decision 3) runs the same
  check on its merged map.
  """
  @spec check(map(), map()) :: :ok | {:error, Exception.t() | [Exception.t()]}
  def check(env_vars, schema) when is_map(env_vars) and is_map(schema) do
    with :ok <- check_all_strings(env_vars) do
      if schema == %{}, do: :ok, else: validate_fields(env_vars, schema)
    end
  end

  defp check_all_strings(env_vars) do
    invalid =
      Enum.filter(env_vars, fn {key, value} -> not is_binary(key) or not is_binary(value) end)

    if Enum.empty?(invalid) do
      :ok
    else
      keys = Enum.map(invalid, fn {key, _value} -> inspect(key) end)

      {:error,
       InvalidAttribute.exception(
         field: :env_vars,
         message:
           "all env var keys and values must be strings (invalid keys: #{Enum.join(keys, ", ")})"
       )}
    end
  end

  # authorize?: false — same shape as DeriveFromAppVersion (the create's
  # own policy carries the actor check; Ash 3 runs create policies after
  # changes).
  # unreachable: create with a nil app_version_id already failed in
  # DeriveFromAppVersion's change
  # coveralls-ignore-next-line
  defp schema_for(nil), do: %{}

  defp schema_for(app_version_id) do
    case Ash.get(AppVersion, app_version_id, authorize?: false) do
      # Empty schema or lookup failure: nothing to check against (a
      # missing version is already reported by DeriveFromAppVersion).
      {:ok, %{configurable_env_vars: schema}} -> schema || %{}
      _other -> %{}
    end
  end

  defp validate_fields(env_vars, schema) do
    errors =
      Enum.flat_map(schema, fn {field, spec} ->
        validate_field(field, spec, Map.get(env_vars, field))
      end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  defp validate_field(field, spec, value) do
    cond do
      spec.required and missing?(value) ->
        [required_error(field)]

      missing?(value) ->
        []

      true ->
        case check_type(spec.type, value) do
          :ok -> []
          {:error, reason} -> [type_error(field, reason)]
        end
    end
  end

  defp missing?(nil), do: true
  defp missing?(""), do: true
  defp missing?(_value), do: false

  defp check_type(:string, _value), do: :ok

  defp check_type(:integer, value) do
    case Integer.parse(value) do
      {_n, ""} -> :ok
      _bad -> {:error, "must be a whole number"}
    end
  end

  defp check_type(:boolean, value) when value in ["true", "false"], do: :ok
  defp check_type(:boolean, _value), do: {:error, ~s(must be "true" or "false")}

  # coveralls-ignore-start - defensive: EnvVarSchema rejects unknown types
  # at write time, so an undeclared type cannot reach here from stored data.
  defp check_type(_unknown, _value), do: :ok
  # coveralls-ignore-stop

  defp required_error(field),
    do: InvalidAttribute.exception(field: :env_vars, message: "#{field} is required")

  defp type_error(field, reason),
    do: InvalidAttribute.exception(field: :env_vars, message: "#{field} #{reason}")

  @impl Validation
  def atomic?, do: false

  @impl Validation
  def describe(_opts) do
    [
      message: "env vars must be strings matching the app version's schema",
      vars: []
    ]
  end
end
