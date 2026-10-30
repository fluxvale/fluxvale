defmodule FluxVale.Infrastructure.Instance.MintDefaultHostnameTest do
  @moduledoc false

  # ADR-0040 S1's instance-create side effect: the org's platform
  # AccessDomain (find-or-create — one row per org) and the default
  # InstanceHostname (label = slug), both pure DB writes inside the
  # create.

  use FluxVale.DataCase, async: true

  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.InstanceHostname
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  setup do
    {org, owner} = BillingFixtures.grant_free_org!()
    {^org, _wallet} = BillingFixtures.funded_wallet!(org: org)

    # Instance create resolves the platform's cluster (ResolveCluster).
    InstanceFixtures.local_cluster!()

    {:ok, org: org, owner: owner}
  end

  test "instance create mints the platform domain and the slug hostname", %{
    org: org,
    owner: owner
  } do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    platform = platform_row!(org)
    assert platform.state == :verified
    assert platform.kind == :platform

    assert platform.domain == Application.fetch_env!(:flux_vale, :instances_base_domain)

    hostname = hostname!(instance.id)
    assert hostname.label == instance.slug
    assert hostname.access_domain_id == platform.id
  end

  test "two instances of one org ride ONE platform row", %{org: org, owner: owner} do
    version = InstanceFixtures.app_version!()

    first =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    second =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    platform = platform_row!(org)

    assert hostname!(first.id).access_domain_id == platform.id
    assert hostname!(second.id).access_domain_id == platform.id

    # Exactly one platform row for the org — find-or-create, not create.
    assert count_platform_rows!(org) == 1
  end

  test "the (access_domain, label) identity makes a double-mint impossible", %{
    org: org,
    owner: owner
  } do
    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    platform = platform_row!(org)

    assert {:error, _conflict} =
             InstanceHostname.mint(
               %{instance_id: instance.id, access_domain_id: platform.id, label: instance.slug},
               authorize?: false
             )
  end

  test "the base domain as platform rows in OTHER orgs never blocks this org's mint", %{
    org: org,
    owner: owner
  } do
    # Per-org :platform rows are same-domain by design — only :custom
    # rows are platform-wide unique (the partial index). authorize?:
    # false — the platform row is system-minted.
    {other_org, _other_owner} = BillingFixtures.grant_free_org!()

    AccessDomain.mint_platform!(
      %{
        domain: Application.fetch_env!(:flux_vale, :instances_base_domain),
        organization_id: other_org.id
      },
      authorize?: false
    )

    version = InstanceFixtures.app_version!()

    instance =
      Instance.create!(
        %{name: "App #{System.unique_integer()}", app_version_id: version.id, env_vars: %{}},
        actor: owner
      )

    platform = platform_row!(org)
    assert platform.organization_id == org.id
    assert hostname!(instance.id).access_domain_id == platform.id
    assert count_platform_rows!(org) == 1
  end

  test "the label grammar is lowercase-only — uppercase is refused", _context do
    # Attribute constraints run before any insert, so unsaved ids are
    # enough to reach the grammar check.
    assert {:error, _changeset} =
             InstanceHostname.mint(
               %{
                 instance_id: Ash.UUID.generate(),
                 access_domain_id: Ash.UUID.generate(),
                 label: "Web"
               },
               authorize?: false
             )
  end

  defp platform_row!(org) do
    AccessDomain
    |> Ash.Query.filter(organization_id == ^org.id and kind == :platform)
    |> Ash.read_one!(authorize?: false)
  end

  defp hostname!(instance_id) do
    InstanceHostname
    |> Ash.Query.filter(instance_id == ^instance_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp count_platform_rows!(org) do
    AccessDomain
    |> Ash.Query.filter(organization_id == ^org.id and kind == :platform)
    |> Ash.count!(authorize?: false)
  end
end
