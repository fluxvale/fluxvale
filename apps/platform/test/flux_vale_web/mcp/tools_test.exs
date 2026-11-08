defmodule FluxValeWeb.Mcp.ToolsTest do
  @moduledoc """
  The nine read tools' wire contract (#361): success paths over real
  action data (the API route suites' fixture patterns), the unwrapped
  `{id, type, attributes}` response shape, the field sets (env_vars
  and status_message never ride), and the policy paths — a cross-org
  id gets the action's not-found posture as a tool error, exactly as
  the HTTP route answers.
  """

  use FluxValeWeb.ConnCase, async: true
  use Mimic

  import FluxVale.TestSupport.Mcp

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.Category
  alias FluxVale.Clients.K8s
  alias FluxVale.Infrastructure.AccessProviders.Tailscale
  alias FluxVale.Infrastructure.BackupRun
  alias FluxVale.Infrastructure.BackupSetting
  alias FluxVale.TestSupport.AccessFixtures
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures

  require Ash.Query

  describe "whoami" do
    test "returns the token's identity, role, and exact scopes", %{conn: conn} do
      {user, pat} = ApiPat.member!(["instances:read", "wallet:read"])
      user_id = user.id
      user_email = to_string(AccountsFixtures.primary_address!(user))

      conn = call_tool(conn, pat, "whoami", %{})

      assert %{
               "id" => ^user_id,
               "type" => "user",
               "attributes" => %{
                 "email" => ^user_email,
                 "platform_role" => "user",
                 "scopes" => ["instances:read", "wallet:read"]
               }
             } = structured(conn)
    end

    test "surfaces the actor's organizations — id, slug and role each", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      personal = AccountsFixtures.personal_org!(user)
      team = AccountsFixtures.owned_org!(user)
      membered = member_org!(user)

      conn = call_tool(conn, pat, "whoami", %{})

      assert %{"attributes" => %{"organizations" => orgs}} = structured(conn)

      by_slug = Map.new(orgs, &{&1["slug"], &1})

      assert by_slug[personal.slug]["id"] == personal.id
      assert by_slug[team.slug]["id"] == team.id
      assert by_slug[membered.slug]["id"] == membered.id

      # The membership row's role: the personal org (JIT provisioning)
      # and the owned org read "owner", the invited-shaped org "member".
      assert by_slug[personal.slug]["role"] == "owner"
      assert by_slug[team.slug]["role"] == "owner"
      assert by_slug[membered.slug]["role"] == "member"

      assert length(orgs) == 3

      # Each row is exactly {id, slug, role} — whoami is the only tool
      # that hands you an org id without demanding one as input, which
      # is what get_wallet / get_gateway take, and the role is what
      # tells an agent what it may do once it is there.
      for row <- orgs do
        keys = Map.keys(row)
        assert MapSet.new(keys) == MapSet.new(~w(id slug role))
      end
    end

    test "a zero-scope token still gets whoami — the tool is scopeless", %{conn: conn} do
      user = AccountsFixtures.user!()
      org = AccountsFixtures.personal_org!(user)
      pat = ApiPat.mint!(user, [])

      conn = call_tool(conn, pat, "whoami", %{})

      org_id = org.id

      assert %{
               "attributes" => %{"scopes" => [], "organizations" => [%{"id" => ^org_id}]}
             } = structured(conn)
    end

    test "a member-less actor ships an empty organizations list", %{conn: conn} do
      {user, pat} = ApiPat.member!()
      org = AccountsFixtures.personal_org!(user)

      # Unreachable through actions (signup's JIT provisioning members
      # the creator) — the system posture stages the seeded/legacy
      # state the operation answers with {:ok, []}.
      drop_membership!(user, org)

      conn = call_tool(conn, pat, "whoami", %{})

      assert %{"attributes" => %{"organizations" => []}} = structured(conn)
    end
  end

  describe "list_instances / get_instance" do
    test "lists the member's instances with the pinned public field set", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user, ["instances:read"])

      instance_id = instance.id

      listing_conn = call_tool(conn, pat, "list_instances", %{})

      assert %{"instances" => [row]} = structured(listing_conn)
      assert %{"id" => ^instance_id, "type" => "instance"} = row

      # The list field set is the /api/v1 route's default_fields.
      attribute_keys = Map.keys(row["attributes"])

      assert MapSet.new(attribute_keys) ==
               MapSet.new(~w(name slug namespace status exposure always_on deployed_at))

      refute Map.has_key?(row["attributes"], "env_vars")
      refute Map.has_key?(row["attributes"], "failure_reason")
    end

    test "returns the detail field set — never env_vars or status_message", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user, ["instances:read"])

      conn = call_tool(conn, pat, "get_instance", %{"id" => instance.id})

      row = structured(conn)
      assert row["id"] == instance.id
      assert row["attributes"]["status"] == "pending"

      attribute_keys = Map.keys(row["attributes"])

      assert MapSet.new(attribute_keys) ==
               MapSet.new(
                 ~w(name slug namespace status exposure always_on image port healthcheck_path) ++
                   ~w(storage_mount_path file_access cpu_cores memory_mb storage_gb deployed_at)
               )

      # The two hide_fields removals — env vars carry deployer
      # credentials; status_message is the #179 admin-only trail.
      refute Map.has_key?(row["attributes"], "env_vars")
      refute Map.has_key?(row["attributes"], "status_message")

      # Decimals cross as literal strings — no float rounding.
      assert row["attributes"]["cpu_cores"] == "0.5"
    end

    test "a cross-org id gets the action's not-found posture, leaking nothing", %{conn: conn} do
      {_user, instance} = member_with_instance()

      # The foreign side needs only a member and a token — no second
      # cluster (ResolveCluster pins one cluster per test).
      foreign_user = elem(ApiPat.member!(["instances:read"]), 0)
      pat = ApiPat.mint!(foreign_user, ["instances:read"])

      conn = call_tool(conn, pat, "get_instance", %{"id" => instance.id})

      refute error_text(conn) =~ instance.name
    end
  end

  describe "list_apps" do
    test "lists the catalog; slug fetches one app", %{conn: conn} do
      {user, app} = catalog_app!()
      pat = ApiPat.mint!(user, ["catalog:read"])

      listing_conn = call_tool(conn, pat, "list_apps", %{})

      assert %{"apps" => [row]} = structured(listing_conn)
      assert row["id"] == app.id
      assert row["attributes"]["slug"] == app.slug

      attribute_keys = Map.keys(row["attributes"])

      assert MapSet.new(attribute_keys) ==
               MapSet.new(
                 ~w(name slug tagline description icon_url source_url docs_url file_access)
               )

      by_slug_conn = call_tool(build_conn(), pat, "list_apps", %{"slug" => app.slug})

      assert %{"apps" => [one]} = structured(by_slug_conn)
      assert one["id"] == app.id
    end

    test "an unknown slug surfaces the action's not-found as a tool error", %{conn: conn} do
      {user, _app} = catalog_app!()
      pat = ApiPat.mint!(user, ["catalog:read"])

      conn = call_tool(conn, pat, "list_apps", %{"slug" => "no-such-app"})

      assert %{"isError" => true} = result(conn)
    end
  end

  describe "get_backup_settings / list_backup_runs" do
    test "returns the settings row — the key id, never the secret", %{conn: conn} do
      {user, instance} = member_with_instance()
      setting = backup_setting!(instance)
      pat = ApiPat.mint!(user, ["backups:read"])

      conn = call_tool(conn, pat, "get_backup_settings", %{"instance_id" => instance.id})

      row = structured(conn)
      assert row["id"] == setting.id
      assert row["type"] == "backup_setting"
      assert row["attributes"]["bucket"] == "fluxvale-kavita"

      attribute_keys = Map.keys(row["attributes"])

      assert MapSet.new(attribute_keys) ==
               MapSet.new(
                 ~w(instance_id endpoint bucket prefix access_key_id retention_keep enabled)
               )
    end

    test "an instance without settings errors with the action's not-found", %{conn: conn} do
      {user, instance} = member_with_instance()
      pat = ApiPat.mint!(user, ["backups:read"])

      conn = call_tool(conn, pat, "get_backup_settings", %{"instance_id" => instance.id})

      assert %{"isError" => true} = result(conn)
    end

    test "lists the run history newest first, honoring limit", %{conn: conn} do
      {user, instance} = member_with_instance()
      older = backup_run!(instance, DateTime.add(DateTime.utc_now(), -3600))
      newer = backup_run!(instance, DateTime.utc_now())
      pat = ApiPat.mint!(user, ["backups:read"])

      conn = call_tool(conn, pat, "list_backup_runs", %{"instance_id" => instance.id})

      newer_id = newer.id
      older_id = older.id

      assert %{"backup_runs" => [first, second]} = structured(conn)
      assert first["id"] == newer_id
      assert second["id"] == older_id
      assert first["attributes"]["status"] == "succeeded"

      # Timestamps cross as ISO-8601 strings (the jsonify contract).
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T/, first["attributes"]["started_at"])

      limited_conn =
        call_tool(
          build_conn(),
          pat,
          "list_backup_runs",
          %{"instance_id" => instance.id, "limit" => 1}
        )

      assert %{"backup_runs" => [only]} = structured(limited_conn)
      assert only["id"] == newer.id
    end

    test "a foreign instance's runs filter to empty, leaking nothing", %{conn: conn} do
      {_user, instance} = member_with_instance()

      foreign_user = elem(ApiPat.member!(["backups:read"]), 0)
      pat = ApiPat.mint!(foreign_user, ["backups:read"])

      conn = call_tool(conn, pat, "list_backup_runs", %{"instance_id" => instance.id})

      assert %{"backup_runs" => []} = structured(conn)
    end
  end

  describe "get_gateway" do
    # The gateway create's ProvisionCluster change reaches the provider
    # even in an authorize?: false fixture — stub it like every gateway
    # suite does.
    setup do
      stub(Tailscale, :provision_gateway, fn _gateway, _key ->
        {:ok, %{credential_secret_ref: "credential-stub"}}
      end)

      stub(K8s, :kubeconfig, fn _ref -> {:ok, %{}} end)
      :ok
    end

    test "returns the org's gateway status row", %{conn: conn} do
      {user, org} = member_org!()
      InstanceFixtures.local_cluster!()
      gateway = AccessFixtures.gateway!(org)
      pat = ApiPat.mint!(user, ["gateways:read"])

      conn = call_tool(conn, pat, "get_gateway", %{"organization_id" => org.id})

      row = structured(conn)
      assert row["id"] == gateway.id
      assert row["type"] == "access_gateway"
      assert row["attributes"]["state"] == "active"
      assert row["attributes"]["hostname"] == gateway.hostname

      attribute_keys = Map.keys(row["attributes"])

      assert MapSet.new(attribute_keys) ==
               MapSet.new(
                 ~w(organization_id hostname tailnet_domain provider state status_message) ++
                   ~w(monthly_cents provisioned_at)
               )

      # Secrets refs and claims stay off the surface.
      refute Map.has_key?(row["attributes"], "credential_secret_ref")
      refute Map.has_key?(row["attributes"], "dns_claims")
    end

    test "another org's gateway is not visible", %{conn: conn} do
      {user, _org} = member_org!()
      {other_org, _other_owner} = BillingFixtures.grant_free_org!()
      InstanceFixtures.local_cluster!()
      AccessFixtures.gateway!(other_org)
      # (the stubs above serve this fixture too)
      pat = ApiPat.mint!(user, ["gateways:read"])

      conn = call_tool(conn, pat, "get_gateway", %{"organization_id" => other_org.id})

      assert %{"isError" => true} = result(conn)
    end
  end

  describe "get_wallet" do
    test "merges the wallet and the runway projection into one response", %{conn: conn} do
      {user, org, wallet} = funded_member_org!(1_500)
      pat = ApiPat.mint!(user, ["wallet:read"])

      wallet_id = wallet.id

      conn = call_tool(conn, pat, "get_wallet", %{"organization_id" => org.id})

      assert %{
               "id" => ^wallet_id,
               "type" => "wallet",
               "attributes" => attrs
             } = structured(conn)

      # No live burn: the balance IS the projection's balance, and the
      # runway is infinity — the atom's name string, the HTTP route's
      # own wire shape.
      assert attrs == %{
               "organization_id" => org.id,
               "balance" => 1_500,
               "paywall_waived" => false,
               "balance_cents" => 1_500,
               "burn_micro_cents_per_hour" => 0,
               "runway_hours" => "infinity"
             }
    end

    test "a foreign org's wallet is not visible", %{conn: conn} do
      {user, _org, _wallet} = funded_member_org!(0)
      {other_org, _other_owner} = BillingFixtures.grant_free_org!()
      pat = ApiPat.mint!(user, ["wallet:read"])

      conn = call_tool(conn, pat, "get_wallet", %{"organization_id" => other_org.id})

      assert %{"isError" => true} = result(conn)
    end
  end

  describe "list_ledger_entries" do
    test "pages the ledger newest first with a keyset cursor", %{conn: conn} do
      {user, _org, wallet} = funded_member_org!(0)
      {:ok, older} = Billing.grant_credits(wallet, 100, reason: :adjustment)
      {:ok, newer} = Billing.grant_credits(wallet, 200, reason: :adjustment)
      pat = ApiPat.mint!(user, ["wallet:read"])
      newer_id = newer.id
      older_id = older.id

      conn =
        call_tool(conn, pat, "list_ledger_entries", %{"wallet_id" => wallet.id, "limit" => 1})

      page_one = structured(conn)
      assert [%{"id" => ^newer_id, "type" => "ledger_entry"}] = page_one["entries"]
      [%{"attributes" => newest}] = page_one["entries"]
      assert newest["amount"] == 200
      assert is_binary(page_one["next_cursor"])

      # Page two rides a fresh conn — the first response was sent.
      page_two_conn =
        call_tool(build_conn(), pat, "list_ledger_entries", %{
          "wallet_id" => wallet.id,
          "limit" => 1,
          "cursor" => page_one["next_cursor"]
        })

      page_two = structured(page_two_conn)
      assert [%{"id" => ^older_id}] = page_two["entries"]

      # Exhausted: the cursor disappears from the response.
      refute Map.has_key?(page_two, "next_cursor")
    end

    test "a foreign wallet's ledger filters to empty, leaking nothing", %{conn: conn} do
      {user, _org, _wallet} = funded_member_org!(0)
      {_other_org, other_wallet} = BillingFixtures.funded_wallet!()
      pat = ApiPat.mint!(user, ["wallet:read"])

      conn = call_tool(conn, pat, "list_ledger_entries", %{"wallet_id" => other_wallet.id})

      # The member filter empties the page, like the HTTP route does —
      # no rows, no cursor.
      page = structured(conn)
      assert %{"entries" => []} = page
      refute Map.has_key?(page, "next_cursor")
    end
  end

  # --- fixtures (the API route suites' patterns) ---------------------

  # A paid+funded member with a pending instance — the population the
  # instance create gate reads (welcome credits fund the wallet).
  defp member_with_instance do
    user = elem(ApiPat.member!(), 0)
    BillingFixtures.mark_user_paid!(user)

    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    instance = InstanceFixtures.instance!(version, user)

    {user, instance}
  end

  defp member_org! do
    user = elem(ApiPat.member!(), 0)
    org = BillingFixtures.mark_user_paid!(user)
    {user, org}
  end

  # `{owner, org, wallet}` with an exact balance (no welcome grant in
  # the mix — the ledger's math stays the fixtures').
  defp funded_member_org!(balance_cents) do
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)

    if balance_cents > 0 do
      {:ok, _grant} = Billing.grant_credits(wallet, balance_cents, reason: :adjustment)
    end

    {owner, org, wallet}
  end

  defp catalog_app! do
    user = elem(ApiPat.member!(), 0)
    n = System.unique_integer()

    category =
      Category.create!(
        %{name: "Tools #{n}", slug: "tools-#{n}", description: "test category"},
        authorize?: false
      )

    app =
      App.create!(
        %{
          name: "App #{n}",
          slug: "app-#{n}",
          tagline: "test app",
          description: "test app",
          category_id: category.id
        },
        authorize?: false
      )

    {user, app}
  end

  defp backup_setting!(instance) do
    BackupSetting
    |> Ash.Changeset.for_create(
      :create,
      %{
        instance_id: instance.id,
        endpoint: "https://account.r2.cloudflarestorage.com",
        bucket: "fluxvale-kavita",
        prefix: "fluxvale/app",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        retention_keep: 7
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # The route suite's two-write shape: create the row, then finalize
  # the outcome fields (:create does not accept them).
  defp backup_run!(instance, started_at) do
    run =
      BackupRun
      |> Ash.Changeset.for_create(
        :create,
        %{instance_id: instance.id, kind: :scheduled, status: :pending, started_at: started_at},
        authorize?: false
      )
      |> Ash.create!()

    run
    |> Ash.Changeset.for_update(
      :update,
      %{
        status: :succeeded,
        snapshot_id: String.duplicate("a", 64),
        finished_at: DateTime.add(started_at, 60)
      },
      authorize?: false
    )
    |> Ash.update!()
  end

  # System posture (bootstrap, mirroring seeds) — the membership destroy
  # is system-only (#119), staging the seeded/legacy member-less state.
  defp drop_membership!(user, org) do
    membership =
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(user_id == ^user.id and organization_id == ^org.id)
      |> Ash.read_one!(authorize?: false)

    Ash.destroy!(membership, authorize?: false)
  end

  # A team org where the user holds the `:member` role: org + membership
  # ride the actions with `authorize?: false` — the bootstrap posture
  # (mirroring seeds), the same shape AccountsFixtures.owned_org!/1
  # uses. The actor-reachable path into an existing org is the invite
  # flow (#441), which carries its own suites.
  defp member_org!(user) do
    n = System.unique_integer([:positive])

    org =
      Organization.create!(%{name: "Member Org #{n}", slug: "member-org-#{n}"},
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: user.id, role: :member},
      authorize?: false
    )

    org
  end
end
