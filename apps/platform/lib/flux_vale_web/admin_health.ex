defmodule FluxValeWeb.AdminHealth do
  @moduledoc """
  The Health section's widget data (#702, ADR-0050 — the operational
  console): one public function per widget, each taking the admin
  actor. C1 ships `fleet/1` — the instance fleet snapshot: build stamp
  (env chip + version), the status spread with totals, and the newest
  deploy trail.

  Every read rides Ash with authorization ON (repo default) — the two
  admissions are distinct: the instance rows ride the platform-admin
  blanket bypass (ActorIsPlatformAdmin outside the machine API,
  #644), while the trail's version rows ride the VersionMixin's
  direct admin-only read policy (ADR-0048 D7). The deploy trail reads
  the Instance Version module through `AdminAudit`'s registry — the
  same string-keyed fetch the audit section's URL segments resolve
  through — and filters `version_action_name == :deploy` — the same
  newest-first grammar the audit section sorts by.
  """

  alias FluxValeWeb.AdminAudit
  alias FluxValeWeb.AdminResource

  # The filter expressions parse through Ash.Expr — the require is
  # load-bearing (the audit section's same note).
  require Ash.Query

  @fleet_deploy_limit 5

  @doc """
  The instance fleet snapshot: every instance read with the admin
  actor, the deploy trail capped at the five newest deploy-action
  version rows. The trail's rows map to the widget's display shape —
  the engine's short id, the recorded actor tombstone, the version's
  own stamp.
  """
  @spec fleet(FluxVale.Identity.User.t()) :: %{
          env: String.t() | nil,
          version: String.t(),
          statuses: %{optional(atom()) => non_neg_integer()},
          total: non_neg_integer(),
          always_on: non_neg_integer(),
          recent_deploys: [
            %{source: String.t(), actor: String.t() | nil, at: DateTime.t()}
          ]
        }
  def fleet(actor) do
    instances = read_instances(actor)

    %{
      env: Application.get_env(:flux_vale, :platform_env),
      version: FluxVale.Build.version(),
      statuses: Enum.frequencies_by(instances, & &1.status),
      total: length(instances),
      always_on: Enum.count(instances, & &1.always_on),
      recent_deploys: recent_deploys(actor)
    }
  end

  defp read_instances(actor) do
    FluxVale.Infrastructure.Instance
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.select([:status, :always_on])
    |> Ash.read!()
  end

  defp recent_deploys(actor) do
    version_module = instance_version_module()

    version_module
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(version_action_name == :deploy)
    |> Ash.Query.sort(version_inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(@fleet_deploy_limit)
    |> Ash.read!()
    |> Enum.map(fn version ->
      %{
        source: AdminResource.short_uuid(version.version_source_id),
        actor: version.actor_label,
        at: version.version_inserted_at
      }
    end)
  end

  # The Instance entry's Version module, resolved the audit section's
  # way: the registry's string-keyed fetch, never a spelled module
  # match. The registry keeping the :instance entry is the doctrine
  # gate's parity invariant (the admin_authority_test pins the
  # business set AdminAudit mirrors), so :error is unreachable while
  # that gate holds — the raise is the honest loud failure if it ever
  # stops holding.
  defp instance_version_module do
    case AdminAudit.fetch("instance") do
      {:ok, entry} ->
        AdminAudit.version_module(entry)

      :error ->
        # coveralls-ignore-start - unreachable while the doctrine gate's
        # parity test holds: it pins the :instance entry into
        # AdminAudit's set (the invariant test in admin_health_test
        # asserts it directly).
        raise ArgumentError,
              "the AdminAudit registry has no :instance entry — " <>
                "the doctrine gate's parity test must keep the business set intact"

        # coveralls-ignore-stop
    end
  end
end
