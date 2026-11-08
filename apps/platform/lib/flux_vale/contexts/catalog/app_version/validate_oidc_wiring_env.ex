defmodule FluxVale.Catalog.AppVersion.ValidateOidcWiringEnv do
  @moduledoc """
  Keeps an OIDC wiring recipe (#597) naming inputs the version actually
  declares: every recipe env name (`issuer_env`, `client_id_env`,
  `client_secret_env`, `enabled_env` when present) must exist in that
  version's `configurable_env_vars`, and the secret env's spec must be
  `secret: true`. A recipe naming an undeclared key would write SSO
  values to an env the deployer never ships (and the wizard never
  hides); a secret on a non-secret spec would land it in plain env.

  Runs on every create/update, so neither the seed YAML nor an
  AshAdmin edit can drift a recipe from its version's inputs — an
  upstream bump that renames env fails here, at catalog write time,
  not at an instance's deploy (#597 §9). Only fires when a recipe is
  present; nil = the version offers no automatic wiring (opt-in per
  version, D4).
  """

  use Ash.Resource.Validation

  alias Ash.Changeset
  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Resource.Validation

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    wiring = Changeset.get_argument_or_attribute(changeset, :oidc_wiring)

    if wiring do
      check_recipe(changeset, wiring)
    else
      :ok
    end
  end

  defp check_recipe(changeset, wiring) do
    specs = Changeset.get_attribute(changeset, :configurable_env_vars)

    errors =
      Enum.reject(
        [
          missing_error(specs, wiring.issuer_env, :issuer_env),
          missing_error(specs, wiring.client_id_env, :client_id_env),
          missing_error(specs, wiring.client_secret_env, :client_secret_env),
          missing_error(specs, wiring.enabled_env, :enabled_env),
          secret_error(specs, wiring)
        ],
        &is_nil/1
      )

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  # enabled_env is the one optional name — nil skips its check.
  defp missing_error(_specs, nil, :enabled_env), do: nil

  defp missing_error(specs, name, field) do
    if Map.has_key?(specs, name) do
      nil
    else
      recipe_error("#{field} #{inspect(name)} is not in this version's configurable_env_vars")
    end
  end

  defp secret_error(specs, wiring) do
    secret_spec = Map.get(specs, wiring.client_secret_env)

    if secret_spec && secret_spec.secret do
      nil
    else
      recipe_error(
        "client_secret_env #{inspect(wiring.client_secret_env)} must name a secret-typed " <>
          "configurable env var (secret: true)"
      )
    end
  end

  defp recipe_error(message) do
    InvalidAttribute.exception(field: :oidc_wiring, message: message)
  end

  @impl Validation
  # coveralls-ignore-next-line trivial callback — always false (multi-attribute check)
  def atomic?, do: false
end
