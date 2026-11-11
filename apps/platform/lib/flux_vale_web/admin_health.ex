defmodule FluxValeWeb.AdminHealth do
  @moduledoc """
  The Health section's widget data (#702, ADR-0050 — the operational
  console): one public function per widget, each taking the admin
  actor. C1 ships `fleet/1` — the instance fleet snapshot: build stamp
  (env chip + version), the status spread with totals, and the newest
  deploy trail.

  Every read rides Ash with authorization ON (repo default) — the
  platform-admin blanket bypass admits the rows, the actor decides,
  never the UI. The deploy trail reads the Instance Version module
  through `AdminAudit`'s registry (the paper-trail introspection, never
  a spelled module name) and filters `version_action_name == :deploy` —
  the same newest-first grammar the audit section sorts by.
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
    |> Ash.Query.select([:name, :status, :always_on, :deployed_at])
    |> Ash.read!()
  end

  defp recent_deploys(actor) do
    entry = Enum.find(AdminAudit.entries(), &(&1.module == FluxVale.Infrastructure.Instance))
    version_module = AdminAudit.version_module(entry)

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
end
