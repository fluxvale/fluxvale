defmodule FluxVale.Infrastructure.InstancePocketIdDetectionTest do
  @moduledoc false

  # #597 §4.1's detection read: the org's ACTIVE Pocket IDs — app
  # slug "pocket-id" (joined through app_version → app), deployed
  # (namespace pinned), not :deleting/:lost, public. One query, the
  # list_for_organization policy posture (member-scoped), newest
  # deployed first — the offer card's default pick and link target.

  # Sync: fabricates app rows with a seeded unique slug (#669).
  use FluxVale.DataCase, async: false

  alias FluxVale.Accounts
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.InstanceK8s
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  setup do
    user = AccountsFixtures.user!()
    InstanceFixtures.local_cluster!()

    pocket_id_version =
      InstanceFixtures.app_version!(app_slug: "pocket-id", configurable_env_vars: %{})

    other_version = InstanceFixtures.app_version!(configurable_env_vars: %{})

    %{user: user, pocket_id_version: pocket_id_version, other_version: other_version}
  end

  # A deployed, running, public instance of `version` — the active
  # shape every exclusion is measured against. The status travels the
  # funnel's legal chain (the fixture's rule); namespace/deployed_at
  # pin after (system-written fields). A `pre` callback runs between
  # create and deploy for the shapes that need it (e.g. a private
  # toggle on the still-never-deployed row — attribute-only there).
  defp deployed_instance!(user, version, deployed_at, pre \\ fn _i -> :ok end) do
    instance = InstanceFixtures.instance!(version, user)
    :ok = pre.(instance)

    running = InstanceFixtures.walk_to!(instance, :running)

    InstanceFixtures.pin!(running,
      namespace: "fluxvale-app-#{instance.id}",
      deployed_at: deployed_at
    )
  end

  # A second org the user belongs to (creator-owner, funded so the
  # create's wallet gate passes) — the cross-org fence's counterpart.
  defp team_org!(user) do
    {:ok, org} =
      Accounts.create_organization(user, %{
        name: "Detect Team",
        slug: "detect-team-#{System.unique_integer([:positive])}"
      })

    BillingFixtures.funded_wallet!(org: org)
    org
  end

  defp personal_detect!(user) do
    org_id = AccountsFixtures.personal_org!(user).id
    Instance.list_active_pocket_ids_for_organization!(org_id, actor: user)
  end

  test "lists the org's deployed public Pocket IDs, newest deployed first", %{
    user: user,
    pocket_id_version: pocket_id_version
  } do
    older = deployed_instance!(user, pocket_id_version, ~U[2026-01-01 00:00:00Z])
    newer = deployed_instance!(user, pocket_id_version, ~U[2026-02-01 00:00:00Z])

    detected = personal_detect!(user)
    assert Enum.map(detected, & &1.id) == [newer.id, older.id]
  end

  test "a private Pocket ID is not active — it serves no issuer (ADR-0038 §4)", %{
    user: user,
    pocket_id_version: pocket_id_version
  } do
    # The real toggle on the never-deployed row is attribute-only (no
    # cluster to apply) — the member-reachable path, not a forced pin.
    make_private = fn instance ->
      Instance.set_exposure!(instance, %{exposure: :private}, actor: user)
      :ok
    end

    private_row =
      deployed_instance!(user, pocket_id_version, ~U[2026-01-01 00:00:00Z], make_private)

    # The detection filter reads the DB row; assert its truth, not a
    # stale funnel struct (the fixture's writes carry their own data).
    reloaded = Instance.get_by_id!(private_row.id, actor: user)
    assert reloaded.exposure == :private
    assert personal_detect!(user) == []
  end

  test "never-deployed, :deleting and :lost Pocket IDs are not active", %{
    user: user,
    pocket_id_version: pocket_id_version
  } do
    never_deployed = InstanceFixtures.instance!(pocket_id_version, user)
    deleting = deployed_instance!(user, pocket_id_version, ~U[2026-01-01 00:00:00Z])
    lost = deployed_instance!(user, pocket_id_version, ~U[2026-01-02 00:00:00Z])

    # :deleting and :lost are enterable through the funnel (any state
    # → :deleting; deployed states → :lost, #196).
    {:ok, _deleting} = InstanceK8s.update_status(deleting, :deleting, "tearing down")
    {:ok, _lost} = InstanceK8s.update_status(lost, :lost, nil)

    assert is_nil(never_deployed.namespace)
    assert personal_detect!(user) == []
  end

  test "other apps stay out; another org's Pocket ID never crosses the fence", %{
    user: user,
    pocket_id_version: pocket_id_version,
    other_version: other_version
  } do
    _other_app_instance = deployed_instance!(user, other_version, ~U[2026-01-01 00:00:00Z])

    team = team_org!(user)

    team_pocket_id =
      Instance.create!(
        %{
          name: "Team Pocket ID",
          app_version_id: pocket_id_version.id,
          organization_id: team.id,
          env_vars: %{}
        },
        actor: user
      )

    team_running = InstanceFixtures.walk_to!(team_pocket_id, :running)

    InstanceFixtures.pin!(team_running,
      namespace: "fluxvale-app-#{team_pocket_id.id}",
      deployed_at: ~U[2026-03-01 00:00:00Z]
    )

    # The personal org holds only the other-app instance: no Pocket
    # IDs. The team org's active Pocket ID is reachable through the
    # SAME member's read of ITS org — and nowhere else.
    assert personal_detect!(user) == []

    team_active = Instance.list_active_pocket_ids_for_organization!(team.id, actor: user)
    assert Enum.map(team_active, & &1.id) == [team_pocket_id.id]

    # A stranger (not a member) reads the org's Pocket IDs as nothing
    # — the read policy filters (list_for_actor's posture).
    stranger = AccountsFixtures.user!()
    personal_org_id = AccountsFixtures.personal_org!(user).id

    assert {:ok, []} =
             Instance.list_active_pocket_ids_for_organization(personal_org_id, actor: stranger)
  end
end
