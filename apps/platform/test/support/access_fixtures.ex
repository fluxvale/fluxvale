defmodule FluxVale.TestSupport.AccessFixtures do
  @moduledoc """
  Preconditions for the access-gateway tests (#268, ADR-0039): an
  action-built `AccessGateway` for an org, and the attachable private
  instance shape.

  The gateway's `create` action runs the provider's cluster leg, so a
  test using these helpers must stub
  `FluxVale.Infrastructure.AccessProviders.Tailscale` (Mimic) — the same
  stance the Instance lifecycle tests take toward the K8s resource
  modules. Tests that exercise the provider itself stub the K8s clients
  instead.
  """

  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  @doc """
  An `:active` gateway for `org` at `monthly_cents`, built through the
  action with the cluster work Mimic-stubbed by the caller.

  Pass `state:` to reach a non-default state through the action's own
  `:update_state` funnel (never a raw write).
  """
  @spec gateway!(map(), keyword()) :: AccessGateway.t()
  def gateway!(org, opts \\ []) do
    monthly_cents = Keyword.get(opts, :monthly_cents, 200)

    gateway =
      AccessGateway.create!(
        %{organization_id: org.id, monthly_cents: monthly_cents, auth_key: "tskey-test"},
        authorize?: false
      )

    gateway
    |> activate!()
    |> maybe_state(Keyword.get(opts, :state))
  end

  # The observed-state write is the only promoter to :active (ADR-0039
  # §2), so tests reach it the same way production does.
  defp activate!(gateway) do
    gateway
    |> Ash.Changeset.for_update(
      :update_state,
      %{state: :active, status_message: "Connected", metering_since: DateTime.utc_now()},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp maybe_state(gateway, nil), do: gateway

  defp maybe_state(gateway, state) do
    gateway
    |> Ash.Changeset.for_update(:update_state, %{state: state}, authorize?: false)
    |> Ash.update!()
  end

  @doc """
  A deployed `:private` instance at `:running` — the attachable shape.

  `user` is the org's member: the create action resolves the org from
  the actor (`SetOrganizationFromActor`), so a system-created row would
  have none.
  """
  @spec private_instance!(map(), map()) :: Instance.t()
  def private_instance!(org, user) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    pinned =
      InstanceFixtures.pin!(instance,
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now(),
        exposure: :private
      )

    set_org!(pinned, org) |> InstanceFixtures.walk_to!(:running)
  end

  @doc "A public instance at :running — the attachable pair's refused half."
  @spec public_instance!(map(), map()) :: Instance.t()
  def public_instance!(org, user) do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: user
      )

    pinned =
      InstanceFixtures.pin!(instance,
        namespace: "fluxvale-app-#{instance.id}",
        deployed_at: DateTime.utc_now()
      )

    set_org!(pinned, org) |> InstanceFixtures.walk_to!(:running)
  end

  # The org is the create action's (`SetOrganizationFromActor`); a
  # system-created instance has none, so tests pin it the way the
  # fixture pins every other system-written field.
  defp set_org!(instance, org) do
    instance
    |> Ash.Changeset.for_update(:update_status, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:organization_id, org.id)
    |> Ash.update!()
  end

  @doc "Marks a running instance :sleeping through the funnel (the wake tests' subject)."
  @spec sleep!(Instance.t()) :: Instance.t()
  def sleep!(instance) do
    {:ok, sleeping} = InstanceK8s.update_status(instance, :sleeping, nil)
    sleeping
  end
end
