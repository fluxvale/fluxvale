defmodule FluxVale.Catalog.AppVersion.ValidateBackingServices do
  @moduledoc """
  Keeps a version's backing-service declarations (#612, ADR-0045)
  consistent with everything else the version declares, and with the
  platform's approved-image registry:

    * every `url_env` exists in the version's `configurable_env_vars`
      — a service URL composed into an env the deployer never ships is
      a silent outage;
    * its spec is `secret: true` — the URL embeds the password; a
      plain-typed spec would land it in visible env;
    * its spec is `required: false` — the platform provides the value,
      and a required platform-owned input deadlocks the deploy wizard;
    * it stays disjoint from the first-run contract's keys (env ∪
      forbidden, case-insensitive like ValidateFirstRunEnv),
      `instance_url_env`, and `host_allowlist_env` — one owner per
      key, each of those layers applies over user env exactly like the
      composed URL does;
    * no duplicate kinds and no duplicate `url_env`s — one service per
      kind, one key per service;
    * the declared major exists in the platform registry for its kind
      (`config :flux_vale, :backing_services`) — an unknown major
      fails the catalog write, not a later deploy.

  Runs on every create/update, so neither the seed YAML nor an
  AshAdmin edit can drift a declaration — the OidcWiring lesson
  (#597): an upstream rename fails here, loudly, at catalog write
  time. Empty list = the version bundles nothing (every existing
  entry; opt-in per version).
  """

  use Ash.Resource.Validation

  alias Ash.Changeset
  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Resource.Validation

  @impl Validation
  def init(opts), do: {:ok, opts}

  @impl Validation
  def validate(changeset, _opts, _context) do
    services = Changeset.get_argument_or_attribute(changeset, :backing_services)

    if services == [] or is_nil(services) do
      :ok
    else
      check_services(changeset, services)
    end
  end

  defp check_services(changeset, services) do
    specs = Changeset.get_attribute(changeset, :configurable_env_vars)

    checks =
      Enum.flat_map(services, &[spec_errors(&1, specs) | cross_field_errors(changeset, &1)]) ++
        [duplicate_kind_error(services), duplicate_url_env_error(services)] ++
        Enum.map(services, &registry_error/1)

    errors = Enum.reject(checks, &is_nil/1)

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  # Per-declaration checks against the version's declared inputs.
  defp spec_errors(service, specs) do
    case Map.fetch(specs, service.url_env) do
      :error ->
        error(
          "url_env #{inspect(service.url_env)} is not in this version's configurable_env_vars"
        )

      {:ok, spec} ->
        secret_error(service, spec) || required_error(service, spec)
    end
  end

  defp secret_error(service, spec) do
    if spec.secret do
      nil
    else
      error(
        "url_env #{inspect(service.url_env)} must name a secret-typed configurable env var " <>
          "(secret: true) — the URL embeds the password"
      )
    end
  end

  defp required_error(service, spec) do
    if spec.required do
      error(
        "url_env #{inspect(service.url_env)} must not be a required input (required: true) " <>
          "— the platform provides it, and a required platform-owned input deadlocks the wizard"
      )
    else
      nil
    end
  end

  # One owner per key: the first-run contract owns its keys, the
  # deployer owns the URL/host seeds. Case-insensitive, folded like
  # ValidateFirstRunEnv — consumers fold env names without preserving
  # case, so an exact-string lock would miss case-variant spellings.
  defp cross_field_errors(changeset, service) do
    url_env = String.downcase(service.url_env)

    [
      contract_error(changeset, url_env),
      seed_field_error(changeset, url_env, :instance_url_env),
      seed_field_error(changeset, url_env, :host_allowlist_env)
    ]
  end

  defp contract_error(changeset, url_env) do
    contract = Changeset.get_attribute(changeset, :first_run)

    if contract do
      keys =
        contract.env
        |> Map.keys()
        |> Kernel.++(contract.forbidden_env)
        |> Enum.map(&String.downcase/1)

      if url_env in keys do
        error(
          "url_env must not be a first-run contract key, got: #{url_env} " <>
            "— the contract is the sole owner of its keys"
        )
      else
        nil
      end
    else
      nil
    end
  end

  defp seed_field_error(changeset, url_env, field) do
    name = Changeset.get_attribute(changeset, field)

    if name && String.downcase(name) == url_env do
      error("url_env #{inspect(name)} collides with #{field} — the deployer owns that key")
    else
      nil
    end
  end

  # One service per kind, one key per service: the deployer renders one
  # container per kind, and a second declaration could only fight the
  # first for the same env key.
  defp duplicate_kind_error(services) do
    kinds = Enum.map(services, & &1.kind)
    duplicates = kinds -- Enum.uniq(kinds)

    if duplicates == [] do
      nil
    else
      error("at most one backing service per kind, duplicate: #{inspect(duplicates)}")
    end
  end

  defp duplicate_url_env_error(services) do
    envs = Enum.map(services, & &1.url_env)
    duplicates = envs -- Enum.uniq(envs)

    if duplicates == [] do
      nil
    else
      error("duplicate url_env #{inspect(Enum.sort(duplicates))} — one owner per key")
    end
  end

  # Registry membership (D2): the platform owns exact pins; entries
  # declare majors. Checked here, never in the type — a
  # config-dependent read inside cast_stored would break stored-row
  # re-reads when the registry grows between writes.
  defp registry_error(service) do
    registry = Application.get_env(:flux_vale, :backing_services, [])
    entries = Keyword.get(registry, service.kind, %{})

    majors =
      entries
      |> Map.keys()
      |> Enum.sort()

    if service.version in majors do
      nil
    else
      error(
        "version #{inspect(service.version)} for kind #{inspect(service.kind)} is not in the " <>
          "platform backing-services registry (approved majors: #{inspect(majors)})"
      )
    end
  end

  defp error(message), do: InvalidAttribute.exception(field: :backing_services, message: message)

  @impl Validation
  # coveralls-ignore-next-line trivial callback — always false (multi-attribute check)
  def atomic?, do: false
end
