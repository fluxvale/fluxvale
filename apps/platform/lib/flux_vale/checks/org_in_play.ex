defmodule FluxVale.Checks.OrgInPlay do
  @moduledoc """
  The one org-in-play resolver the wallet gates share
  (`ActorOrgHasPaid`, `ActorOrgWalletFunded`): which organization a
  paywall policy question is about, answered from the action's shape.
  One module, one discipline — the wallet gates cannot fork (#510).
  `ActorOwnsPaidOrg` deliberately keeps its own simpler variant
  (org-scoped rows, no instance hop — see its moduledoc).

  Create vs update comes from the changeset's action type, never from
  a nil attribute (a forged `organization_id: nil` on an update must
  not reroute the gate to the caller's own wallet). Creates resolve
  the org the row will carry: a create that NAMES its instance
  (`BackupSetting`) reads THAT instance's org; one that names its org
  (the #408 context — the Instance create argument, the gateway's
  compat argument, set on the attribute by the tenancy change before
  policies run) gates on THAT org's ledger; one naming neither
  (unreachable through the guarded actions today — the tenancy
  changes always pin an org for an actor) answers `:actor` and the
  check resolves the actor's personal org. Updates re-read the ROW
  from the database: an in-process caller controls the changeset's
  in-memory struct, and the gate must not be caller-controlled. The
  row's org rides `organization_id` directly, or THROUGH the row's
  instance (a `BackupSetting` belongs to its instance, not the
  organization). Any org that cannot resolve fails closed (`:error`),
  as does any non-changeset subject and any atomic placeholder.
  """

  @doc """
  Resolves the org a wallet-gate question is about.

  `{:ok, org_id}` — the gate reads that org. `:actor` — a create
  named neither an instance nor an org, so the check falls back to the
  actor's personal org (the caller decides what an orgless actor
  means; `ActorOrgHasPaid`/`ActorOrgWalletFunded` pass, letting the
  create's own `organization_id is required` validation answer
  instead of a bare Forbidden). `:error` — fail closed.
  """
  @spec org_in_play(term()) :: {:ok, Ash.UUID.t()} | :actor | :error
  def org_in_play(%Ash.Changeset{action_type: :create} = changeset),
    do: create_org_id(changeset)

  # Atomic changesets carry this placeholder — Ash.reload would raise
  # on it — and no org resolves from it: fail closed.
  def org_in_play(%Ash.Changeset{data: %Ash.Changeset.OriginalDataNotAvailable{}}),
    do: :error

  def org_in_play(%Ash.Changeset{data: data}) do
    case Ash.reload(data, authorize?: false) do
      {:ok, fresh_row} -> row_org(fresh_row)
      {:error, _reload_failure} -> :error
    end
  end

  def org_in_play(_subject), do: :error

  # A create resolves the org the row will carry. A create that NAMES
  # its instance (BackupSetting) resolves the org from THAT instance —
  # the row's org — never the actor's personal one (a team-org instance
  # must not answer on the member's wallet, either direction). One that
  # names its org (the #408 context, set on the attribute by the tenancy
  # change before policies run) gates on THAT org's ledger. Attribute
  # first, then argument, covering both intake shapes.
  #
  # Accepted-with-rationale: a create whose input carries a
  # relationship-shaped instance instead of a concrete `instance_id`
  # does not reach this resolver — the action's own Required
  # validation answers (the orgless-actor posture), so the actor arm
  # is never consulted on a foreign org. Revisit trigger: the day
  # :create accepts relationship-shaped instances, resolve the org
  # from the relationship here.
  defp create_org_id(%Ash.Changeset{} = changeset) do
    instance_id =
      Ash.Changeset.get_attribute(changeset, :instance_id) ||
        Map.get(changeset.arguments, :instance_id)

    case instance_id do
      nil -> named_org_id(changeset)
      instance_id -> instance_org_id(instance_id)
    end
  end

  # The named-org arm: the row's org is known at policy time (the
  # tenancy change ran with the changeset), so the gate reads the org
  # the row will carry — the named org's wallet, not the actor's
  # personal one.
  defp named_org_id(changeset) do
    org_id =
      Ash.Changeset.get_attribute(changeset, :organization_id) ||
        Map.get(changeset.arguments, :organization_id)

    case org_id do
      nil -> :actor
      org_id -> {:ok, org_id}
    end
  end

  # Fresh authorize-free read, the same fail-closed discipline as
  # updates: an instance that cannot resolve (deleted under the
  # changeset, a DB outage) answers :error, never the actor path.
  defp instance_org_id(instance_id) do
    case Ash.get(FluxVale.Infrastructure.Instance, instance_id, authorize?: false) do
      {:ok, %{organization_id: org_id}} when not is_nil(org_id) -> {:ok, org_id}
      _unresolved -> :error
    end
  end

  # The org rides the row directly (organization_id) or THROUGH the
  # row's instance (BackupSetting belongs_to :instance, not the
  # organization — resolve it one hop along the same FK the policies
  # read). A row whose org cannot be resolved fails closed.
  defp row_org(%{organization_id: org_id}) when not is_nil(org_id), do: {:ok, org_id}

  defp row_org(row) do
    case Ash.load(row, :instance, authorize?: false) do
      {:ok, %{instance: %{organization_id: org_id}}} when not is_nil(org_id) ->
        {:ok, org_id}

      # coveralls-ignore-start - defensive: the belongs_to FK guarantees
      # the instance (a cascade never leaves the row behind it) and the
      # instance's organization_id is not nullable, so the load either
      # resolves or the DB is gone — which ExUnit cannot simulate
      # (DBConnection reconnects — the repo's cluster-level stance).
      _unresolved ->
        :error
        # coveralls-ignore-stop
    end
  end
end
