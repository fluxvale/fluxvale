defmodule FluxVale.Infrastructure.Instance.DeriveFromAppVersion do
  @moduledoc """
  Snapshots the AppVersion's deploy blueprint onto the Instance at create:
  `image`, `port`, `healthcheck_path`, `storage_mount_path`,
  `file_access` (from the App, #190), `cpu_cores`,
  `memory_mb`, `storage_gb`, the env merge — user values over operator
  `default_env_vars` over `configurable_env_vars` schema defaults, all
  stringified (env vars are strings end to end; ValidateEnvVars
  type-checks them after changes run), with the first-run contract's
  `env` applied **above** every layer (#181, ADR-0034) — and the
  pricing snapshot (#121/#186):
  the version's `recommended_size` plus both cents and
  `grandfathered_until = created_at + 1 year` at the recommendation —
  or, for a custom allocation, the anchor formula's cents with the
  same 1-year clock and no size — so price and clock come from one
  moment (creation-time pricing with a 1-year grace; settlement reads
  live prices only after it lapses).

  Allocation (#180): the version's `default_cpu_cores`/
  `default_memory_mb`/`default_storage_gb` are the advisory
  recommendation — applied only when the creator sends no allocation.
  A user-chosen allocation (above or below the recommendation, floor-
  bounded by the attribute constraints) wins unchanged; the wizard owns
  the below-recommendation warning + acknowledgment, not the derive.

  The Instance is the snapshot, not the live version: editing an
  AppVersion later never mutates a running Instance's spec (same stance
  as v1's derive, ported) — nor its price while grandfathered.

  A version without a `recommended_size` (pre-#125 seed drift) creates
  an unpriced instance: settle no-ops on it, loudly logged — billing
  never guesses a price.
  """

  use Ash.Resource.Change

  alias FluxVale.Catalog.AppVersion

  @grandfather_years 1

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    app_version_id = Ash.Changeset.get_attribute(changeset, :app_version_id)

    if app_version_id do
      # authorize?: false (v1's shape, kept): Ash 3 evaluates create
      # policies *after* changes, so an authorized nested read would make
      # an actorless create die here with a misleading "version not
      # found" before the policy layer returns Forbidden. The Instance
      # create's own policy carries the actor check; catalog rows are
      # signed-in-readable.
      case Ash.get(AppVersion, app_version_id, authorize?: false) do
        {:ok, version} ->
          app = Ash.load!(version, :app, authorize?: false).app

          changeset
          |> Ash.Changeset.force_change_attribute(:image, version.image)
          |> Ash.Changeset.force_change_attribute(:port, version.port)
          |> Ash.Changeset.force_change_attribute(:healthcheck_path, version.healthcheck_path)
          |> Ash.Changeset.force_change_attribute(:file_access, app.file_access)
          |> Ash.Changeset.force_change_attribute(
            :storage_mount_path,
            version.storage_mount_path
          )
          |> Ash.Changeset.force_change_attribute(
            :cpu_cores,
            chosen(changeset, :cpu_cores, version.default_cpu_cores)
          )
          |> Ash.Changeset.force_change_attribute(
            :memory_mb,
            chosen(changeset, :memory_mb, version.default_memory_mb)
          )
          |> Ash.Changeset.force_change_attribute(
            :storage_gb,
            chosen(changeset, :storage_gb, version.default_storage_gb)
          )
          |> snapshot_price(version)
          |> merge_env_defaults(version)

        # A create with a bogus app_version_id: report it on the field
        # (catalog reads are actor-scoped; a version another actor can't
        # read is indistinguishable from a missing one here).
        {:error, _error} ->
          Ash.Changeset.add_error(changeset,
            field: :app_version_id,
            message: "selected app version not found"
          )
      end
    else
      # unreachable: app_version_id is allow_nil? false — nil dies at
      # cast/auto-validation before the change runs
      # coveralls-ignore-next-line
      Ash.Changeset.add_error(changeset, field: :app_version_id, message: "is required")
    end
  end

  # The user's allocation wins over the recommendation (#180); absent
  # (not sent) falls back to the version's default. fetch_change, not
  # get_attribute: the latter reads the record's attribute default as
  # if chosen (Ash applies attribute defaults after action changes).
  # An explicit nil (a crafted save) reads as absent — the nil-able
  # attrs accept it at cast, and nil flowing into the allocation
  # comparison or the curve would crash the change.
  defp chosen(changeset, key, recommended) do
    case Ash.Changeset.fetch_change(changeset, key) do
      {:ok, nil} -> recommended
      {:ok, value} -> value
      :error -> recommended
    end
  end

  # Creation-time pricing (#121/#186): at the recommendation the Size
  # row snapshots (size_id + cents + the 1-year clock); a custom
  # allocation prices by the anchor formula instead — cents + clock
  # snapshot the same way, no size (settlement reads the live formula
  # from the instance's allocation after the grace lapses). A sizeless
  # version at the recommendation stays unpriced (pre-#125 drift —
  # billing never guesses), but a custom allocation on it prices fine:
  # the formula needs no size.
  defp snapshot_price(changeset, version) do
    size = Ash.load!(version, :recommended_size, authorize?: false).recommended_size

    if custom_allocation?(changeset, version) do
      snapshot_formula_price(changeset)
    else
      snapshot_size_price(changeset, size)
    end
  end

  defp snapshot_size_price(changeset, nil), do: changeset

  defp snapshot_size_price(changeset, size) do
    changeset
    |> Ash.Changeset.force_change_attribute(:size_id, size.id)
    |> Ash.Changeset.force_change_attribute(:grandfathered_monthly_cents, size.monthly_cents)
    |> Ash.Changeset.force_change_attribute(
      :grandfathered_stopped_monthly_cents,
      size.stopped_monthly_cents
    )
    |> snapshot_grace_clock()
  end

  # The effective allocation (chosen dimension over the version's
  # default) priced by the one formula (#186). The allocation
  # force-changes above have already run, so get_attribute reads the
  # effective values straight off the changeset.
  defp snapshot_formula_price(changeset) do
    allocation = %{
      cpu_cores: Ash.Changeset.get_attribute(changeset, :cpu_cores),
      memory_mb: Ash.Changeset.get_attribute(changeset, :memory_mb),
      storage_gb: Ash.Changeset.get_attribute(changeset, :storage_gb)
    }

    rates = FluxVale.Pricing.price_allocation(allocation)

    changeset
    |> Ash.Changeset.force_change_attribute(:grandfathered_monthly_cents, rates.monthly_cents)
    |> Ash.Changeset.force_change_attribute(
      :grandfathered_stopped_monthly_cents,
      rates.stopped_monthly_cents
    )
    |> snapshot_grace_clock()
  end

  # A custom allocation: any dimension differs from the version's
  # defaults. Runs after the allocation force-changes above — the
  # changeset already carries the effective values (chosen or the
  # version's default), so the comparison is in place; absent dims read
  # as the default, i.e. the recommendation, and snapshot the size as
  # before #186.
  defp custom_allocation?(changeset, version) do
    cpu = Ash.Changeset.get_attribute(changeset, :cpu_cores)
    memory = Ash.Changeset.get_attribute(changeset, :memory_mb)
    storage = Ash.Changeset.get_attribute(changeset, :storage_gb)

    cpu_off = not Decimal.eq?(cpu, version.default_cpu_cores)
    memory_off = memory != version.default_memory_mb
    storage_off = storage != version.default_storage_gb

    cpu_off or memory_off or storage_off
  end

  defp snapshot_grace_clock(changeset) do
    one_year = DateTime.shift(DateTime.utc_now(), year: @grandfather_years)
    Ash.Changeset.force_change_attribute(changeset, :grandfathered_until, one_year)
  end

  # user values > operator default_env_vars > configurable schema
  # defaults — operator-explicit beats the catalog's form-suggested
  # default when both name a key (both stringified) — and the
  # first-run contract above all (#181, ADR-0034): a user value naming
  # a contract key (`env` ∪ `forbidden_env`) is rejected loudly, never
  # silently overridden — a forbidden key set at deploy time is exactly
  # the #181 failure mode, and no admin-provisioning path exists to
  # undo it.
  defp merge_env_defaults(changeset, version) do
    user_env_vars = Ash.Changeset.get_attribute(changeset, :env_vars) || %{}

    conflicts = contract_conflicts(user_env_vars, version.first_run)

    if conflicts == [] do
      operator_defaults = stringified(version.default_env_vars)
      schema_suggestions = schema_defaults(version.configurable_env_vars)

      # Contract env merges last: the guarantee outranks every
      # deploy-time layer. Write-time disjointness
      # (ValidateFirstRunEnv) keeps the lower layers from naming these
      # keys; merging last holds the guarantee even for drifted rows.
      with_operator = Map.merge(schema_suggestions, operator_defaults)
      with_user = Map.merge(with_operator, user_env_vars)
      merged = Map.merge(with_user, contract_env(version.first_run))

      Ash.Changeset.force_change_attribute(changeset, :env_vars, merged)
    else
      Ash.Changeset.add_error(changeset,
        field: :env_vars,
        message:
          "cannot be set at deploy time, fixed by the app's first-run contract " <>
            "(#{Enum.join(conflicts, ", ")})"
      )
    end
  end

  defp contract_env(nil), do: %{}

  defp contract_env(contract), do: contract.env

  defp contract_conflicts(_user_env_vars, nil), do: []

  # Case-insensitive, reporting the user's own spelling: consumers fold
  # env names onto config settings without preserving case (Forgejo's
  # environment-to-ini lowercases ini sections), so an exact-string
  # lock would miss FORGEJO__Service__… variants of a contract key —
  # whole-name folding is the conservative superset.
  defp contract_conflicts(user_env_vars, contract) do
    contract_keys =
      contract
      |> contract_key_list()
      |> Enum.map(&String.downcase/1)
      |> MapSet.new()

    user_env_vars
    |> Map.keys()
    |> Enum.filter(fn key -> MapSet.member?(contract_keys, String.downcase(key)) end)
    |> Enum.sort()
  end

  defp contract_key_list(contract), do: Map.keys(contract.env) ++ contract.forbidden_env

  defp stringified(map) do
    Map.new(map, fn {key, value} -> {key, to_string(value)} end)
  end

  defp schema_defaults(schema) do
    schema
    |> Enum.filter(fn {_name, spec} -> not is_nil(spec.default) end)
    |> Map.new(fn {name, spec} -> {name, to_string(spec.default)} end)
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end
