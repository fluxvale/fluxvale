defmodule FluxVale.Catalog.AppVersion.ValidateFirstRunEnv do
  @moduledoc """
  Keeps the first-run contract the sole owner of its keys (#181,
  ADR-0034): `first_run.env` ∪ `first_run.forbidden_env` must stay
  disjoint from `default_env_vars`, `configurable_env_vars`, and the
  version's `instance_url_env` — the deployer applies that one *over*
  the merged env at Secret-build time, so a contract key hiding there
  would silently outrank the contract. One key, one home: a contract
  key reappearing as an operator default or a deploy-time toggle would
  fork the guarantee, and (for a forbidden key) break first open
  exactly as #181 shipped.

  Comparison is case-insensitive: consumers fold env names onto config
  settings without preserving case (Forgejo's environment-to-ini
  lowercases ini sections), so an exact-string lock would miss
  case-variant spellings of a contract key.

  Runs on every create/update, so neither the seed YAML nor an
  AshAdmin edit can drift the layers into conflict. Only fires when a
  contract is present; a nil `first_run` is a version that needs no
  first-open posture (e.g. usable out of the box).
  """

  use Ash.Resource.Validation

  alias Ash.Changeset
  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Resource.Validation

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    contract = Changeset.get_argument_or_attribute(changeset, :first_run)

    if contract do
      check_disjoint(changeset, contract)
    else
      :ok
    end
  end

  defp check_disjoint(changeset, contract) do
    contract_keys = folded_contract_keys(contract)

    errors =
      Enum.reject(
        [
          overlap_error(changeset, contract_keys, :default_env_vars),
          overlap_error(changeset, contract_keys, :configurable_env_vars),
          instance_url_error(changeset, contract_keys)
        ],
        &is_nil/1
      )

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  defp folded_contract_keys(contract) do
    contract
    |> contract_key_list()
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp contract_key_list(contract), do: Map.keys(contract.env) ++ contract.forbidden_env

  defp overlap_error(changeset, contract_keys, attribute) do
    overlap =
      changeset
      |> Changeset.get_attribute(attribute)
      |> Map.keys()
      |> Enum.filter(&MapSet.member?(contract_keys, String.downcase(&1)))
      |> Enum.sort()

    if overlap == [] do
      nil
    else
      contract_key_error(attribute, overlap)
    end
  end

  defp instance_url_error(changeset, contract_keys) do
    name = Changeset.get_attribute(changeset, :instance_url_env)

    if name && MapSet.member?(contract_keys, String.downcase(name)) do
      contract_key_error(:instance_url_env, [name])
    else
      nil
    end
  end

  defp contract_key_error(field, overlap) do
    InvalidAttribute.exception(
      field: :first_run,
      message:
        "first-run contract keys must not appear in #{field} " <>
          "(#{Enum.join(overlap, ", ")}) — the contract is the sole owner of its keys"
    )
  end

  @impl Validation
  # coveralls-ignore-next-line trivial callback — always false (multi-attribute check)
  def atomic?, do: false
end
