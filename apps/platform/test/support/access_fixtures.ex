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

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Clients.K8s.Resources.Pod
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  @doc """
  An `:active` gateway for `org` at `monthly_cents`, built through the
  action with the cluster work Mimic-stubbed by the caller.

  Pass `state:` to reach a non-default state through the action's own
  `:update_state` funnel (never a raw write). Pass `tailnet_domain:`
  to exercise a different suffix (it defaults to the test tailnet).
  """
  @spec gateway!(map(), keyword()) :: AccessGateway.t()
  def gateway!(org, opts \\ []) do
    monthly_cents = Keyword.get(opts, :monthly_cents, 200)
    tailnet_domain = Keyword.get(opts, :tailnet_domain, "example.ts.net")

    gateway =
      AccessGateway.create!(
        %{
          organization_id: org.id,
          monthly_cents: monthly_cents,
          tailnet_domain: tailnet_domain,
          auth_key: "tskey-test"
        },
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

  @doc """
  Stubs `Pod.list_by_labels/3` to return one running gateway pod at `ip`.
  Use in test setups that reach the access arms without asserting on
  gateway pod selection directly.
  """
  @spec stub_gateway_pod(String.t()) :: module()
  def stub_gateway_pod(ip \\ "10.0.0.9") do
    Mimic.stub(Pod, :list_by_labels, fn _kc, _ns, _labels ->
      {:ok, [running_pod(ip)]}
    end)
  end

  @doc """
  A `:custom` `AccessDomain` for `org` in its born-`:pending` state,
  registered through the action (the wildcard Certificate mint rides
  the caller's Kubereq/K8s stubs). The name is unique per test.
  """
  @spec custom_domain!(Organization.t()) :: AccessDomain.t()
  def custom_domain!(org) do
    name = "apps-#{System.unique_integer([:positive])}.customer.test"

    AccessDomain.register!(
      %{domain: name, organization_id: org.id},
      actor: org_actor!(org.id),
      authorize?: false
    )
  end

  @doc """
  A `:custom` `AccessDomain` promoted to `:verified` WITH its wildcard
  cert ref recorded — the only shape the verify pass produces (the
  promoter runs from an observed Ready Certificate).
  """
  @spec verified_domain!(Organization.t()) :: AccessDomain.t()
  def verified_domain!(org) do
    domain = custom_domain!(org)

    {:ok, verified} =
      AccessDomain.mark_verified(
        domain,
        %{cert_secret_ref: "cert-secret-#{System.unique_integer([:positive])}"},
        authorize?: false
      )

    verified
  end

  @doc """
  A `:custom` `AccessDomain` in `:needs_attention` — reached the honest
  way: verified with its cert ref recorded first (needs_attention is
  only ever a demotion OF a verified row), then flagged.
  """
  @spec needs_attention_domain!(Organization.t()) :: AccessDomain.t()
  def needs_attention_domain!(org) do
    domain = verified_domain!(org)
    {:ok, flagged} = AccessDomain.mark_needs_attention(domain, authorize?: false)
    flagged
  end

  @doc """
  Mints one `InstanceHostname` row (`label.domain`) for the instance
  under the domain — the system `:mint` action, `authorize?: false`.
  """
  @spec mint_hostname!(Instance.t(), AccessDomain.t(), String.t()) ::
          InstanceHostname.t()
  def mint_hostname!(instance, domain, label) do
    {:ok, hostname} =
      InstanceHostname.mint(
        %{instance_id: instance.id, access_domain_id: domain.id, label: label},
        authorize?: false
      )

    hostname
  end

  @doc """
  Replaces the gateway's `dns_claims` with one claim per name (the
  observed-state write the platform never makes on its own).
  """
  @spec claim!(AccessGateway.t(), [String.t()]) :: AccessGateway.t()
  def claim!(gateway, names) do
    claims =
      Map.new(names, fn name ->
        {name, %{"ip" => "10.43.0.20", "tailnet" => "example.ts.net"}}
      end)

    {:ok, claimed} =
      AccessGateway.update_claims(gateway, %{dns_claims: claims}, authorize?: false)

    claimed
  end

  # The register action's org change needs an actor even with a named
  # org (the fixture's bootstrap posture); the owner is the honest one.
  defp org_actor!(organization_id) do
    Membership
    |> Ash.Query.filter(organization_id == ^organization_id and role == :owner)
    |> Ash.read_one!(authorize?: false)
  end

  defp running_pod(ip) do
    %{
      "metadata" => %{"creationTimestamp" => "2026-11-01T02:00:00Z"},
      "status" => %{"phase" => "Running", "podIP" => ip}
    }
  end
end
