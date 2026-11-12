defmodule FluxValeWeb.AdminResourcesLiveTest do
  @moduledoc false

  # The generic resource console's read path (#595 slice 1, proven on
  # Ops): the picker pages, the index with typed cells and pagination,
  # the actor-safe show page, the honest 404s for unknown segments,
  # and BOTH gates (the route pipeline and the AdminGate socket
  # re-check). Write mounts are slice 2 — none exist here.

  use FluxValeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Ash.Resource.Info
  alias FluxVale.Accounts.Membership
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Billing.Wallet
  alias FluxVale.Catalog.App
  alias FluxVale.Catalog.AppVersion
  alias FluxVale.Catalog.Category
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.Pricing.Size
  alias FluxVale.Pricing.TaxRate
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.AdminConsole
  alias FluxValeWeb.AdminLive.Resources

  require Ash.Query

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-resources-admin-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # Preconditions through the resource's own actions with the admin
  # actor — the repo convention.
  defp flag!(admin, attrs \\ %{}) do
    suffix =
      @n
      |> Integer.to_string(36)
      |> String.downcase()

    key = "res_flag_#{suffix}_#{System.unique_integer([:positive])}"

    FeatureFlag
    |> Ash.Changeset.for_create(:create, Map.merge(%{key: key}, attrs), actor: admin)
    |> Ash.create!()
  end

  defp rule!(admin, attrs) do
    email = "res-rule-#{System.unique_integer()}@fluxvale.com"

    AccessRule
    |> Ash.Changeset.for_create(:create, Map.merge(%{email: email}, attrs), actor: admin)
    |> Ash.create!()
  end

  # Slice 3's domains: sizes and tax rates through their own actions,
  # and any wallet the admin's read arm reaches (the admin's org
  # provisions one at user create — any user's wallet proves the
  # cross-org arm).
  defp size!(admin, attrs) do
    slug = "res-size-#{System.unique_integer([:positive])}"

    Size
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{slug: slug, cpu_cores: Decimal.new("2.5"), memory_mb: 2048, monthly_cents: 1500},
        attrs
      ),
      actor: admin
    )
    |> Ash.create!()
  end

  defp tax_rate!(admin, attrs) do
    TaxRate
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{country: "DE", rate_bp: 1900, effective_from: DateTime.utc_now()}, attrs),
      actor: admin
    )
    |> Ash.create!()
  end

  defp any_wallet!(admin) do
    Wallet
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: admin)
    |> List.first()
  end

  # A stranger's org and its wallet: the org's only members are fresh
  # accounts (never the admin), so a rendered row is a cross-org read
  # by shape.
  defp stranger_org_wallet! do
    {org, _owner} = BillingFixtures.grant_free_org!()

    stranger =
      User.create!(
        "admin-resources-stranger-#{System.unique_integer([:positive])}@fluxvale.com",
        %{},
        authorize?: false
      )

    Membership.create!(%{organization_id: org.id, user_id: stranger.id, role: :member},
      authorize?: false
    )

    {:ok, wallet} = Billing.ensure_wallet(org)
    {org, wallet}
  end

  # Slice 4's domains: catalog rows through their own :create actions.
  # App requires file_access and category_id (not nullable); the
  # version fixture is the probe-verified valid blueprint — the backing
  # service's url_env must name a secret configurable env var
  # (ValidateBackingServices) and the recommended size must match the
  # version's compute defaults (ValidateSizeMatchesAllocation), so the
  # size rides the same allocation the fixture defaults carry.
  defp category!(admin) do
    Category
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Tools", slug: "cat-tools-#{System.unique_integer([:positive])}"},
      actor: admin
    )
    |> Ash.create!()
  end

  defp app!(admin, category) do
    App
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Probe App",
        slug: "app-#{System.unique_integer([:positive])}",
        file_access: false,
        category_id: category.id
      },
      actor: admin
    )
    |> Ash.create!()
  end

  defp version!(admin, app, size, attrs \\ %{}) do
    defaults =
      Map.merge(
        %{
          version: "1.2.3",
          image: "fluxvale/app:1.2.3",
          port: 3000,
          healthcheck_path: "/",
          storage_mount_path: "/data",
          default_env_vars: %{"A" => "1"},
          configurable_env_vars: %{
            "PORT" => %{"label" => "Port", "type" => "integer"},
            "DATABASE_URL" => %{"label" => "Database URL", "type" => "string", "secret" => true}
          },
          backing_services: [
            %{"kind" => "postgres", "version" => "18", "url_env" => "DATABASE_URL"}
          ],
          default_cpu_cores: Decimal.new("0.5"),
          default_memory_mb: 256,
          default_storage_gb: 1,
          app_id: app.id,
          recommended_size_id: size.id
        },
        attrs
      )

    AppVersion
    |> Ash.Changeset.for_create(:create, defaults, actor: admin)
    |> Ash.create!()
  end

  # The version's recommended size at the fixture's compute defaults.
  defp sized_size!(admin) do
    size!(admin, %{cpu_cores: Decimal.new("0.5"), memory_mb: 256})
  end

  # The wallet index's label column is id (no name-ish attr), so one
  # cell testid per row carries the id column prefix.
  defp wallet_index_ids(view) do
    html = render(view)
    document = LazyHTML.from_fragment(html)

    matches = LazyHTML.query(document, "[data-testid^='admin-resource-cell-id-']")

    Enum.to_list(matches)
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp index_row_count(view) do
    html = render(view)
    document = LazyHTML.from_fragment(html)

    matches = LazyHTML.query(document, "[data-testid^='admin-resource-cell-key-']")

    length(Enum.to_list(matches))
  end

  describe "the landing and the domain picker (D3)" do
    test "the landing cards the live domains and marks the sidebar entry as the page", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/admin/resources")

      assert has_element?(view, "[data-testid='admin-resources-domain-ops']", "Ops")
      assert has_element?(view, "[data-testid='admin-resources-domain-ops']", "2 resources")

      entry = render(element(view, "[data-testid='admin-nav-resources']"))
      assert entry =~ ~s(aria-current="page")
    end

    test "a crafted ?domain= query cannot remount the landing as a domain page", %{
      conn: conn
    } do
      # The arms key on live_action, never on merged query params — the
      # landing stays the landing under any query string.
      {:ok, view, _html} = live(conn, "/admin/resources?domain=nope")

      assert has_element?(view, "[data-testid='admin-resources-domains']")
      refute has_element?(view, "[data-testid='admin-resources-domain']")
    end

    test "the domain page cards its resources, note copy included", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops")

      assert has_element?(
               view,
               "[data-testid='admin-resources-resource-feature_flag']",
               "Feature flag"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resources-resource-access_rule']",
               "Access rule"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resources-resource-access_rule']",
               "exactly one of domain or email"
             )

      entry = render(element(view, "[data-testid='admin-nav-resources']"))
      assert entry =~ ~s(aria-current="location")
      refute entry =~ ~s(aria-current="page")
    end
  end

  describe "the domain-divided sidebar navigation (D3 revised)" do
    test "the landing renders every domain group collapsed and says what the sidebar shows", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/admin/resources")

      assert has_element?(view, "[data-testid='admin-sidebar-domain-ops']")
      refute has_element?(view, "[data-testid='admin-sidebar-domain-ops'][open]")
      refute has_element?(view, "details[open]")

      assert has_element?(
               view,
               "[data-testid='admin-resources-pending']",
               "The sidebar groups every live domain here under Resources, collapsed to start."
             )
    end

    test "a resource index opens its domain's group and marks its leaf as the page", %{
      conn: conn,
      admin: admin
    } do
      flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      assert has_element?(view, "[data-testid='admin-sidebar-domain-ops'][open]")

      leaf = render(element(view, "[data-testid='admin-nav-resource-ops-feature_flag']"))
      assert leaf =~ ~s(aria-current="page")

      # One marked entry per surface: the landing entry goes quiet.
      landing = render(element(view, "[data-testid='admin-nav-resources']"))
      refute landing =~ "aria-current"
    end

    test "a record's sub-route marks its leaf as an ancestor, not the page", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      assert has_element?(view, "[data-testid='admin-sidebar-domain-ops'][open]")

      leaf = render(element(view, "[data-testid='admin-nav-resource-ops-feature_flag']"))
      assert leaf =~ ~s(aria-current="location")
      refute leaf =~ ~s(aria-current="page")
    end

    test "a non-console surface renders every domain group collapsed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      assert has_element?(view, "[data-testid='admin-sidebar-domain-ops']")
      refute has_element?(view, "details[open]")
    end
  end

  describe "route resolution honesty" do
    test "an unknown domain segment bounces to the landing with the honest flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources", flash: flash}}} =
               live(conn, "/admin/resources/nope")

      assert flash["error"] == "That page does not exist here."
    end

    test "an unknown resource segment bounces the same way", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources", flash: flash}}} =
               live(conn, "/admin/resources/ops/nope")

      assert flash["error"] == "That page does not exist here."
    end

    test "the show route's own unknown-segment arm bounces too — id and all", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources"}}} =
               live(conn, "/admin/resources/ops/nope/ffffffff-ffff-7fff-8fff-ffffffffffff")
    end

    test "the flash lands and the landing still renders", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources"}}} =
               live(conn, "/admin/resources/nope")

      {:ok, view, _html} = live(conn, "/admin/resources")
      assert has_element?(view, "[data-testid='admin-resources-domain-ops']")
    end
  end

  describe "the index" do
    test "renders rows with typed cells in the console's table grammar", %{
      conn: conn,
      admin: admin
    } do
      flag =
        flag!(admin, %{enabled: true, rollout_percentage: 42, description: "slice one proof"})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      assert has_element?(view, "[data-testid='admin-resource-col-key']", "Key")
      assert has_element?(view, "[data-testid='admin-resource-col-enabled']", "Enabled")

      assert has_element?(
               view,
               "[data-testid='admin-resource-col-rollout_percentage']",
               "Rollout percentage"
             )

      assert has_element?(view, "[data-testid='admin-resource-col-description']", "Description")
      assert has_element?(view, "[data-testid='admin-resource-col-created_at']", "Created at")

      assert text_of(view, "[data-testid='admin-resource-cell-key-#{flag.id}']") == flag.key
      assert text_of(view, "[data-testid='admin-resource-cell-enabled-#{flag.id}']") == "Yes"

      assert text_of(view, "[data-testid='admin-resource-cell-rollout_percentage-#{flag.id}']") ==
               "42"

      assert text_of(view, "[data-testid='admin-resource-cell-description-#{flag.id}']") ==
               "slice one proof"

      assert text_of(view, "[data-testid='admin-resource-cell-created_at-#{flag.id}']") ==
               Calendar.strftime(flag.created_at, "%b %d, %Y")

      assert has_element?(
               view,
               "a[data-testid='admin-resource-view-#{flag.id}']",
               "View"
             )
    end

    test "a boolean off reads No and unset values read Not set", %{conn: conn, admin: admin} do
      flag = flag!(admin, %{enabled: false})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      assert text_of(view, "[data-testid='admin-resource-cell-enabled-#{flag.id}']") == "No"

      assert text_of(view, "[data-testid='admin-resource-cell-rollout_percentage-#{flag.id}']") ==
               "Not set"
    end

    test "every rendered column is a public attribute or a declared timestamp — nothing else", %{
      conn: conn,
      admin: admin
    } do
      flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      html = render(view)
      document = LazyHTML.from_fragment(html)

      matches = LazyHTML.query(document, "[data-testid^='admin-resource-col-']")

      rendered =
        for match <- Enum.to_list(matches) do
          [testid] = LazyHTML.attribute(match, "data-testid")
          String.replace_prefix(testid, "admin-resource-col-", "")
        end
        |> MapSet.new()

      # The actor-safety ceiling for the index (the plan's amended
      # parity criterion 2): curated columns, but every one of them
      # resolves to a public attribute or a DECLARED framework
      # timestamp. updated_at is declared and never rendered (only
      # created_at is pinned), so the assertion is the subset ceiling
      # plus the pinned stamp's presence — a subset the show page's
      # exact-equality test complements, not duplicates.
      public =
        FeatureFlag
        |> Info.public_attributes()
        |> Enum.map(&Atom.to_string(&1.name))
        |> MapSet.new()

      declared =
        FeatureFlag
        |> Resources.declared_timestamp_names()
        |> MapSet.new()

      allowed = MapSet.union(public, declared)

      assert MapSet.subset?(rendered, allowed)
      assert MapSet.member?(rendered, "created_at")
      assert MapSet.member?(rendered, "key")
    end

    test "rows run newest first", %{conn: conn, admin: admin} do
      older = flag!(admin)
      newest = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.query(document, "[data-testid^='admin-resource-cell-key-']")

      keys =
        for match <- Enum.to_list(matches) do
          text = LazyHTML.text(match)
          String.trim(text)
        end

      assert keys == [newest.key, older.key]
    end

    test "an empty table says so honestly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      assert has_element?(view, "[data-testid='admin-resource-empty']", "No rows yet.")
      assert has_element?(view, "[data-testid='admin-resource-count']", "0 rows")
      refute has_element?(view, "[data-testid='admin-resource-table']")
    end

    test "the note banner carries the registry's note copy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/access_rule")

      assert has_element?(
               view,
               "[data-testid='admin-resource-note']",
               "Rows carry exactly one of domain or email, never both."
             )
    end

    test "ci_string renders as plain text, its original case — no case games", %{
      conn: conn,
      admin: admin
    } do
      rule = rule!(admin, %{email: "Mixed.Case@FluxVale.COM", purpose: :feedback})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/access_rule")

      assert text_of(view, "[data-testid='admin-resource-cell-email-#{rule.id}']") ==
               "Mixed.Case@FluxVale.COM"

      # purpose: the atom enum renders humanized in a neutral badge
      assert has_element?(
               view,
               "[data-testid='admin-resource-cell-purpose-#{rule.id}']",
               "Feedback"
             )
    end
  end

  describe "pagination (25 to a page, count-aware)" do
    setup %{admin: admin} do
      flags = for _i <- 1..26, do: flag!(admin)
      %{flags: flags}
    end

    test "page one shows 25 of 26 with page controls", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      assert index_row_count(view) == 25
      assert has_element?(view, "[data-testid='admin-resource-count']", "26 rows")
      assert has_element?(view, "a[data-testid='admin-resource-page-2']")
      assert has_element?(view, "a[data-testid='admin-resource-next']")
    end

    test "page two shows the straggler — the oldest row", %{conn: conn, flags: flags} do
      oldest = List.first(flags)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag?page=2")

      assert index_row_count(view) == 1
      assert has_element?(view, "[data-testid='admin-resource-cell-key-#{oldest.id}']")
    end

    test "a page past the end bounces to the real last page", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources/ops/feature_flag?page=2"}}} =
               live(conn, "/admin/resources/ops/feature_flag?page=99")
    end

    test "a crafted 19-digit page never reaches the offset math as a bignum", %{conn: conn} do
      # The parse caps at the page bound, so the huge page reads as the
      # bound — past the end, bounced to the real last page, no crash.
      assert {:error, {:live_redirect, %{to: "/admin/resources/ops/feature_flag?page=2"}}} =
               live(conn, "/admin/resources/ops/feature_flag?page=9999999999999999999")
    end

    test "garbage page params read as page one", %{conn: conn} do
      {:ok, abc_view, _html} = live(conn, "/admin/resources/ops/feature_flag?page=abc")
      assert index_row_count(abc_view) == 25

      {:ok, negative_view, _html} = live(conn, "/admin/resources/ops/feature_flag?page=-3")
      assert index_row_count(negative_view) == 25

      {:ok, list_view, _html} = live(conn, "/admin/resources/ops/feature_flag?page%5B%5D=2")
      assert index_row_count(list_view) == 25
    end
  end

  describe "the show page" do
    test "renders exactly the public attributes — actor-safe by set equality", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin, %{enabled: true, description: "show me"})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      html = render(view)
      document = LazyHTML.from_fragment(html)

      matches = LazyHTML.query(document, "[data-testid^='admin-resource-field-']")

      rendered =
        for match <- Enum.to_list(matches) do
          [testid] = LazyHTML.attribute(match, "data-testid")
          String.replace_prefix(testid, "admin-resource-field-", "")
        end
        |> MapSet.new()

      public =
        FeatureFlag
        |> Info.public_attributes()
        |> Enum.map(&Atom.to_string(&1.name))
        |> MapSet.new()

      # The demanded assertion: the rendered field set EQUALS the
      # public set — every public attribute present, nothing else.
      assert MapSet.equal?(rendered, public)
      assert MapSet.member?(rendered, "id")
      refute MapSet.member?(rendered, "created_at")
      refute MapSet.member?(rendered, "updated_at")
    end

    test "values render typed: full uuid copyable, integers and strings in full", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin, %{enabled: true, rollout_percentage: 40, description: "show me"})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      assert has_element?(view, "[data-testid='admin-resource-uuid']", flag.id)
      assert has_element?(view, "[data-testid='admin-resource-copy-id']")

      assert text_of(view, "[data-testid='admin-resource-field-enabled'] span") == "Yes"

      assert has_element?(view, "[data-testid='admin-resource-field-description']", "show me")
    end

    test "the record label names the page — the label heuristic's pick", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      assert has_element?(view, "[data-testid='admin-resources-title']", flag.key)
    end

    test "a nil label attribute falls back to the short id — a domain-only rule has no email", %{
      conn: conn,
      admin: admin
    } do
      # :feedback, not :auth: an :auth row gates session/token
      # presentation too (ADR-0023), and writing one would bounce this
      # test's own admin session at the gate — the resource working as
      # designed, just not what this test is about.
      rule =
        AccessRule
        |> Ash.Changeset.for_create(:create, %{domain: "example.org", purpose: :feedback},
          actor: admin
        )
        |> Ash.create!()

      {:ok, view, _html} = live(conn, "/admin/resources/ops/access_rule/#{rule.id}")

      assert has_element?(
               view,
               "[data-testid='admin-resources-title']",
               FluxValeWeb.AdminResource.short_uuid(rule.id)
             )
    end

    test "an unknown record id flashes and bounces to the index (the size-edit posture)", %{
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: "/admin/resources/ops/feature_flag"}}} =
               live(
                 conn,
                 "/admin/resources/ops/feature_flag/ffffffff-ffff-7fff-8fff-ffffffffffff"
               )
    end

    test "a garbage id lands the same way — no crash on uncastable input", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources/ops/feature_flag"}}} =
               live(conn, "/admin/resources/ops/feature_flag/not-a-uuid")
    end
  end

  describe "the gates (both arms)" do
    test "anonymous bounces to sign-in at the route gate" do
      conn = get(build_conn(), "/admin/resources/ops")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403 at the route gate", %{bare_conn: conn} do
      user = User.create!("admin-resources-user-#{@n}@fluxvale.com", %{}, authorize?: false)

      conn =
        conn
        |> SessionHelpers.sign_in(user)
        |> get("/admin/resources/ops/feature_flag")

      assert conn.status == 403
    end

    test "a bearer-only socket bounces at mount (AdminGate re-checks the session)", %{
      admin: admin
    } do
      # The PAT satisfies the route pipeline, but the socket carries no
      # session — the on_mount re-check is the arm that answers.
      pat = ApiPat.mint!(admin, ["instances:read"])
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(conn, "/admin/resources/ops/feature_flag")
    end
  end

  describe "configured columns and label overrides (the registry's curated lists)" do
    # Slices 4-5 trim wide resources through these keys; the resolution
    # rules are the trap the hostile review flagged — honored NOW, with
    # tests, so a later config typo degrades to a missing column
    # instead of a crash or a non-public reveal.
    defp entry(config) do
      %{
        domain: %{key: :ops, label: "Ops", module: FluxVale.Ops},
        key: :feature_flag,
        module: FeatureFlag,
        config: config
      }
    end

    test "a curated list resolves each name to a public attribute or declared timestamp, in order" do
      curated = entry(%{columns: [:key, :created_at]})
      columns = Resources.columns(curated)

      assert Enum.map(columns, & &1.name) == [:key, :created_at]
    end

    test "an inert name is skipped — never a crash, never a non-public attribute" do
      curated = entry(%{columns: [:key, :renamed_attr]})
      columns = Resources.columns(curated)

      # The inert name skips; the created_at pin still rides the
      # configured list (the engine's columns contract).
      assert Enum.map(columns, & &1.name) == [:key, :created_at]
    end

    test "a label override honors public attributes only — a stale name falls back" do
      honored_entry = entry(%{label_attr: :description})
      honored = Resources.columns(honored_entry)

      stale_entry = entry(%{label_attr: :updated_at})
      stale = Resources.columns(stale_entry)

      unknown_entry = entry(%{label_attr: :nope})
      unknown = Resources.columns(unknown_entry)

      # description is public and honored; updated_at (declared
      # timestamp, not public) and :nope both fall back to the
      # heuristic's pick.
      assert hd(honored).name == :description
      assert hd(stale).name == :key
      assert hd(unknown).name == :key
    end
  end

  # -- slice 2: the write path ------------------------------------------------

  # The fabricated-entry seam for the selector tests (the
  # configured-columns idiom above): config drives resolution without
  # touching the live registry.
  defp write_entry(config) do
    %{
      domain: %{key: :ops, label: "Ops", module: FluxVale.Ops},
      key: :feature_flag,
      module: FeatureFlag,
      config: config
    }
  end

  describe "the create mount (:new)" do
    test "renders the typed input mapping over the accept list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/new")

      assert has_element?(view, "#admin-resource-record-form")

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-key'] input[type='text'][required]"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-enabled'] input[type='checkbox']"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-enabled'] input[type='checkbox']"
             )

      refute has_element?(view, "[data-testid='admin-resource-input-enabled'] input[required]")

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-rollout_percentage'] input[type='number']"
             )

      refute has_element?(
               view,
               "[data-testid='admin-resource-input-rollout_percentage'] input[required]"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-description'] input[type='text']"
             )

      assert has_element?(view, "[data-testid='admin-resource-save']", "Create Feature flag")
    end

    test "the enum select carries the declared atoms as its options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/access_rule/new")

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-purpose'] select option[value='auth']",
               "Auth"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-purpose'] select option[value='feedback']",
               "Feedback"
             )

      # The attribute's declared default preselects — no blank option
      # on a required select.
      assert has_element?(
               view,
               "[data-testid='admin-resource-input-purpose'] select option[value='auth'][selected]"
             )
    end

    test "the note banner rides the form when the registry sets one", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/access_rule/new")

      assert has_element?(view, "[data-testid='admin-resource-note']")
    end

    test "creates through the form and lands on the record's show page", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/new")

      redirect =
        view
        |> form("#admin-resource-record-form",
          record: %{
            "key" => "created_by_console",
            "enabled" => "true",
            "rollout_percentage" => "40",
            "description" => "the write path works"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = redirect
      assert to =~ "/admin/resources/ops/feature_flag/"
      assert to =~ ~r/[0-9a-f-]{36}$/

      {:ok, flag} = FeatureFlag.by_key("created_by_console", actor: admin)
      assert flag.enabled == true
      assert flag.rollout_percentage == 40
    end

    test "constraint failures render inline beside their field — no navigation", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/new")

      html =
        view
        |> form("#admin-resource-record-form",
          record: %{"key" => "Bad Key!", "rollout_percentage" => "150"}
        )
        |> render_submit()

      # Both constraints at once: the key regex and the rollout bounds,
      # each beside its own field (the <.input> error slot).
      assert html =~ "must match the pattern"
      assert html =~ "must be less than or equal to"

      assert has_element?(view, "[data-testid='admin-resource-form']")
      assert {:error, _not_created} = FeatureFlag.by_key("Bad Key!", actor: admin)
    end

    test "the AccessRule one-of rule lands on both shape fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/access_rule/new")

      html =
        view
        |> form("#admin-resource-record-form", record: %{"purpose" => "feedback"})
        |> render_submit()

      assert html =~ "exactly 1 of domain,email must be present"
      assert has_element?(view, "[data-testid='admin-resource-form']")
    end

    test "?action= picks among the allowed create actions and anything else bounces honestly",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/new?action=create")
      assert has_element?(view, "#admin-resource-record-form")

      for crafted <- ["destroy", "by_key", "update", "nope"] do
        assert {:error,
                {:live_redirect, %{to: "/admin/resources/ops/feature_flag", flash: flash}}} =
                 live(conn, "/admin/resources/ops/feature_flag/new?action=#{crafted}")

        assert flash["error"] == "That action is not available here."
      end
    end

    test "an unknown resource segment bounces the same way the read mounts do", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources", flash: flash}}} =
               live(conn, "/admin/resources/ops/nope/new")

      assert flash["error"] == "That page does not exist here."

      assert {:error, {:live_redirect, %{to: "/admin/resources"}}} =
               live(
                 conn,
                 "/admin/resources/ops/nope/ffffffff-ffff-7fff-8fff-ffffffffffff/edit"
               )
    end

    test "the live validate path renders inline errors while typing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/new")

      html = render_change(view, "validate", %{"record" => %{"key" => "Bad Key!"}})

      assert html =~ "must match the pattern"
      assert has_element?(view, "[data-testid='admin-resource-form']")
    end

    test "crafted event payloads are quiet no-ops, never crashes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/new")

      # A validate or save with no record params under the form's name.
      render_change(view, "validate", %{"nonsense" => "true"})
      html = render_submit(view, "save", %{"nonsense" => "true"})

      assert has_element?(view, "[data-testid='admin-resource-form']")
      assert html =~ "Create Feature flag"

      # An open-destroy with no action value never opens a confirm.
      render_click(view, "open-destroy", %{})
      refute has_element?(view, "[data-testid='destructive-confirm']")
    end
  end

  describe "the edit mount (:edit)" do
    test "renders the record's current values prefilled", %{conn: conn, admin: admin} do
      flag = flag!(admin, %{enabled: true, rollout_percentage: 30, description: "prefill me"})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}/edit")

      assert has_element?(view, "#admin-resource-record-form")
      assert render(element(view, "[data-testid='admin-resource-input-key'] input")) =~ flag.key

      assert render(
               element(view, "[data-testid='admin-resource-input-rollout_percentage'] input")
             ) =~
               "30"

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-enabled'] input[type='checkbox'][checked]"
             )
    end

    test "updates through the form and lands on the record's show page", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin, %{rollout_percentage: 10})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}/edit")

      view
      |> form("#admin-resource-record-form", record: %{"rollout_percentage" => "75"})
      |> render_submit()

      assert_redirect(view, "/admin/resources/ops/feature_flag/#{flag.id}")

      {:ok, fresh} = Ash.get(FeatureFlag, flag.id, actor: admin)
      assert fresh.rollout_percentage == 75
    end

    test "an invalid update renders inline and keeps the record unchanged", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin, %{rollout_percentage: 10})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}/edit")

      html =
        view
        |> form("#admin-resource-record-form", record: %{"rollout_percentage" => "101"})
        |> render_submit()

      assert html =~ "must be less than or equal to"

      {:ok, fresh} = Ash.get(FeatureFlag, flag.id, actor: admin)
      assert fresh.rollout_percentage == 10
    end

    test "an unknown record id bounces to the index (the size-edit posture)", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources/ops/feature_flag"}}} =
               live(
                 conn,
                 "/admin/resources/ops/feature_flag/ffffffff-ffff-7fff-8fff-ffffffffffff/edit"
               )
    end

    test "?action= resolves update actions and wrong-type names bounce to the record's page", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} =
        live(conn, "/admin/resources/ops/feature_flag/#{flag.id}/edit?action=update")

      assert has_element?(view, "#admin-resource-record-form")

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/resources/ops/feature_flag/#{flag.id}/edit?action=create")

      assert to == "/admin/resources/ops/feature_flag/#{flag.id}"
      assert flash["error"] == "That action is not available here."
    end
  end

  describe "destroy (the confirm-gated write)" do
    test "the show page's actions bar carries the gated Edit link and Delete button", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      assert has_element?(view, "[data-testid='admin-resource-actions']")
      assert has_element?(view, "a[data-testid='admin-resource-edit-update']", "Edit")
      assert has_element?(view, "[data-testid='admin-resource-destroy-destroy']", "Delete")
    end

    test "the confirm names the record by its label and states irreversibility", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      render_click(view, "open-destroy", %{"action" => "destroy"})

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "Delete #{flag.key}?"
             )

      assert has_element?(
               view,
               "[data-testid='destructive-confirm']",
               "This permanently deletes the record"
             )
    end

    test "cancel closes the confirm without running anything", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      render_click(view, "open-destroy", %{"action" => "destroy"})
      render_click(view, "cancel-confirm", %{})

      refute has_element?(view, "[data-testid='destructive-confirm']")

      assert {:ok, _still_there} = Ash.get(FeatureFlag, flag.id, actor: admin)
    end

    test "confirm deletes the record and returns to the index with the flash", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      render_click(view, "open-destroy", %{"action" => "destroy"})

      confirm = element(view, "[data-testid='admin-resource-destroy-confirm']")
      render_click(confirm)

      assert_redirect(view, "/admin/resources/ops/feature_flag")

      assert {:error, _gone} = Ash.get(FeatureFlag, flag.id, actor: admin)
    end

    test "the quiet expired arm: a confirm with the panel closed is a no-op", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      # The double-click shape: the first click navigated away, the
      # second lands on a closed panel (also the crafted-event shape).
      render_click(view, "confirm-destroy", %{})

      assert has_element?(view, "[data-testid='admin-resource-show']")
      assert {:ok, _still_there} = Ash.get(FeatureFlag, flag.id, actor: admin)
    end

    test "a crafted action value never opens a confirm", %{conn: conn, admin: admin} do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      render_click(view, "open-destroy", %{"action" => "nope"})

      refute has_element?(view, "[data-testid='destructive-confirm']")
    end

    test "a record deleted out-of-band answers both the open and the confirm honestly",
         %{conn: conn, admin: admin} do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      render_click(view, "open-destroy", %{"action" => "destroy"})
      assert has_element?(view, "[data-testid='destructive-confirm']")

      # Out-of-band delete between the open and the confirm: the
      # dispatch re-reads through the domain before destroying.
      changeset = Ash.Changeset.for_destroy(flag, :destroy, %{}, actor: admin)
      Ash.destroy!(changeset)

      confirm = element(view, "[data-testid='admin-resource-destroy-confirm']")
      render_click(confirm)

      assert_redirect(view, "/admin/resources/ops/feature_flag")

      # And the open arm reads the same honesty.
      flag2 = flag!(admin)
      {:ok, view2, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag2.id}")

      changeset2 = Ash.Changeset.for_destroy(flag2, :destroy, %{}, actor: admin)
      Ash.destroy!(changeset2)

      render_click(view2, "open-destroy", %{"action" => "destroy"})

      assert_redirect(view2, "/admin/resources/ops/feature_flag")
    end
  end

  describe "the index's create affordance" do
    test "the New link points at the :new route when policy permits", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag")

      assert has_element?(view, "a[data-testid='admin-resource-new']", "New")
    end
  end

  describe "the demotion window (every write re-resolves the actor)" do
    test "a mid-session demotion cannot create: the submit is refused with honest copy", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/new")

      demote!(admin)

      html =
        view
        |> form("#admin-resource-record-form",
          record: %{"key" => "demoted_create", "enabled" => "true"}
        )
        |> render_submit()

      assert html =~ "Your admin access ended. Sign out and sign back in."
      assert {:error, _refused} = FeatureFlag.by_key("demoted_create", actor: admin)
    end

    test "a mid-session demotion cannot update: the record keeps its values", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin, %{rollout_percentage: 10})

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}/edit")

      demote!(admin)

      html =
        view
        |> form("#admin-resource-record-form", record: %{"rollout_percentage" => "99"})
        |> render_submit()

      assert html =~ "Your admin access ended. Sign out and sign back in."

      {:ok, fresh} = Ash.get(FeatureFlag, flag.id, actor: admin)
      assert fresh.rollout_percentage == 10
    end

    test "a mid-session demotion cannot destroy: the confirm is refused", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      render_click(view, "open-destroy", %{"action" => "destroy"})
      assert has_element?(view, "[data-testid='destructive-confirm']")

      demote!(admin)

      confirm = element(view, "[data-testid='admin-resource-destroy-confirm']")
      render_click(confirm)

      assert has_element?(view, "#flash-error", "Your admin access ended")
      assert {:ok, _still_there} = Ash.get(FeatureFlag, flag.id, actor: admin)
    end
  end

  describe "policy enforcement (the demanded non-admin proof)" do
    test "a signed-in non-admin bounces at the route gate on every write route", %{
      bare_conn: conn
    } do
      user = User.create!("admin-resources-writer-#{@n}@fluxvale.com", %{}, authorize?: false)

      for path <- [
            "/admin/resources/ops/feature_flag/new",
            "/admin/resources/ops/feature_flag"
          ] do
        request =
          conn
          |> SessionHelpers.sign_in(user)
          |> get(path)

        assert request.status == 403
      end
    end

    test "a bearer-only socket bounces at mount on the write routes too", %{admin: admin} do
      pat = ApiPat.mint!(admin, ["instances:read"])
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(conn, "/admin/resources/ops/feature_flag/new")
    end

    test "visible? hides every write action for a non-admin actor" do
      user = User.create!("admin-resources-probe-#{@n}@fluxvale.com", %{}, authorize?: false)

      for resource <- [FeatureFlag, AccessRule],
          action <- [:create, :update, :destroy] do
        refute AdminConsole.visible?(user, resource, action)
      end
    end

    test "non-admin actors are Forbidden on the write paths themselves", %{
      admin: admin
    } do
      non_admin = SessionHelpers.user!()

      assert {:error, %Ash.Error.Forbidden{}} =
               FeatureFlag
               |> Ash.Changeset.for_create(:create, %{key: "forbidden_create"}, actor: non_admin)
               |> Ash.create()

      flag = flag!(admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               flag
               |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: non_admin)
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               flag
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: non_admin)
               |> Ash.destroy()
    end
  end

  describe "the Pricing rollout (slice 3: full CRUD on Size and TaxRate)" do
    test "the size index renders rows with the decimal raw — no currency inference", %{
      conn: conn,
      admin: admin
    } do
      size = size!(admin, %{slug: "res-size-pricing-index", cpu_cores: Decimal.new("3.5")})

      {:ok, view, _html} = live(conn, "/admin/resources/pricing/size")

      assert has_element?(view, "[data-testid='admin-resource-cell-slug-#{size.id}']")
      assert render(view) =~ "3.5"
      refute render(view) =~ "3.5 €"
    end

    test "an operator creates a size through the typed form and lands on its show page", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/admin/resources/pricing/size/new")

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-slug'] input[type='text'][required]"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-cpu_cores'] input[type='number'][step='0.01']"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-memory_mb'] input[type='number']"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-monthly_cents'] input[type='number']"
             )

      result =
        view
        |> form("#admin-resource-record-form",
          record: %{
            "slug" => "created-by-console",
            "cpu_cores" => "2.5",
            "memory_mb" => "2048",
            "monthly_cents" => "1500"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to =~ "/admin/resources/pricing/size/"
    end

    test "the tax rate form rides the datetime-local input and casts", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/pricing/tax_rate/new")

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-effective_from'] input[type='datetime-local'][required]"
             )

      redirect =
        view
        |> form("#admin-resource-record-form",
          record: %{
            "country" => "DE",
            "rate_bp" => "1900",
            "effective_from" => "2026-01-01T00:00"
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = redirect
      assert to =~ "/admin/resources/pricing/tax_rate/"
    end

    test "the tax rate edit form carries only its update accept list (rate_bp)", %{
      conn: conn,
      admin: admin
    } do
      rate = tax_rate!(admin, %{country: "FR"})

      {:ok, view, _html} =
        live(conn, "/admin/resources/pricing/tax_rate/#{rate.id}/edit")

      assert has_element?(view, "[data-testid='admin-resource-input-rate_bp']")
      refute has_element?(view, "[data-testid='admin-resource-input-country']")
      refute has_element?(view, "[data-testid='admin-resource-input-effective_from']")
    end
  end

  describe "the Billing rollout (slice 3: the constrained operator set)" do
    test "the wallet index renders org wallets — the admin reads cross-org", %{
      conn: conn,
      admin: admin
    } do
      _own = any_wallet!(admin)
      SessionHelpers.user!()

      {:ok, view, _html} = live(conn, "/admin/resources/billing/wallet")

      # Two orgs exist with a wallet each (the admin's and the fresh
      # user's), and no create affordance renders: creates are
      # registry-excluded for Wallet.
      wallet_cells = wallet_index_ids(view)
      assert length(wallet_cells) >= 2
      refute has_element?(view, "[data-testid='admin-resource-new']")
    end

    test "a wallet of an org the admin is not a member of renders — the blanket widened the engine (#644)",
         %{
           conn: conn,
           admin: admin
         } do
      # A stranger's org with a wallet: the admin is provably NOT a
      # member (the membership-refuted shape the curated surfaces'
      # pins use), and the engine's index read passes regardless.
      #
      # Honesty about what this pin can fail for: Wallet's read policy
      # carries its OWN pre-doctrine platform-admin arm (the wallets
      # lane's #140/#501 arm), so this test pins the SURFACE
      # visibility — the engine renders cross-org rows — as a belt
      # over the armed read, not the doctrine. The DOCTRINE-level
      # regression pins (resources whose only admin path is the
      # blanket bypass) live at the policy layer:
      # test/flux_vale/admin_authority_policy_test.exs pins the
      # un-armed cross-org reads (Organization's primary read,
      # Membership and invite rosters, Topup, another org's Instance
      # and Feedback rows) against the member-scoped baseline. An
      # ENGINE-level bypass-only pin lands with the Infrastructure
      # registry slice, whose org-scoped resources carry no
      # pre-doctrine arm.
      {org, wallet} = stranger_org_wallet!()

      refute Membership
             |> Ash.Query.filter(organization_id == ^org.id and user_id == ^admin.id)
             |> Ash.exists?(actor: admin)

      _own = any_wallet!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/billing/wallet")

      assert has_element?(view, "[data-testid='admin-resource-cell-id-#{wallet.id}']")
    end

    test "the wallet show carries only the waiver edit — system actions never render", %{
      conn: conn,
      admin: admin
    } do
      wallet = any_wallet!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/billing/wallet/#{wallet.id}")

      assert has_element?(view, "[data-testid='admin-resource-edit-set_waiver']")
      refute has_element?(view, "[data-testid='admin-resource-edit-set_carryover']")
      refute has_element?(view, "[data-testid='admin-resource-edit-set_ladder_state']")
      refute has_element?(view, "[data-testid^='admin-resource-destroy-']")
    end

    test "?action=set_waiver on :new bounces — no create action is allowed", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources/billing/wallet", flash: flash}}} =
               live(conn, "/admin/resources/billing/wallet/new?action=set_waiver")

      assert flash["error"] == "That action is not available here."
    end

    test "the waiver edit saves through the checkbox", %{conn: conn, admin: admin} do
      wallet = any_wallet!(admin)

      {:ok, view, _html} =
        live(conn, "/admin/resources/billing/wallet/#{wallet.id}/edit?action=set_waiver")

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-paywall_waived'] input[type='checkbox']"
             )

      # The flash rides the redirect token (decoded by the router on
      # landing); the destination is the wallet's show page.
      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#admin-resource-record-form", record: %{"paywall_waived" => "true"})
               |> render_submit()

      assert to == "/admin/resources/billing/wallet/#{wallet.id}"
    end

    test "the ledger index renders enum badges for type and reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/billing/ledger_entry")

      # Every wallet carries a welcome :credit entry (auto-provisioned).
      assert render(view) =~ "Credit"
      assert has_element?(view, "[data-testid='admin-resource-enum']")
    end

    test "the goodwill form takes its inputs as arguments, not accepted attrs", %{
      conn: conn,
      admin: admin
    } do
      wallet = any_wallet!(admin)

      {:ok, view, _html} = live(conn, "/admin/resources/billing/ledger_entry/new")

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-wallet_id'] input[type='text'][required]"
             )

      assert has_element?(
               view,
               "[data-testid='admin-resource-input-amount_cents'] input[type='number'][required]"
             )

      # accept([]): no attribute field renders at all.
      refute has_element?(view, "[data-testid='admin-resource-input-amount']")
      refute has_element?(view, "[data-testid='admin-resource-input-reason']")

      redirect =
        view
        |> form("#admin-resource-record-form",
          record: %{"wallet_id" => wallet.id, "amount_cents" => "500"}
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = redirect
      assert to =~ "/admin/resources/billing/ledger_entry/"

      # The entry posted through the canonical goodwill seam: an
      # :adjustment credit of 500 cents on that wallet.
      segments = String.split(to, "/")
      entry_id = List.last(segments)

      entry =
        LedgerEntry
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id == ^entry_id)
        |> Ash.read_one!(actor: admin)

      assert entry.amount == 500
      assert entry.reason == :adjustment
      assert entry.type == :credit
      assert entry.wallet_id == wallet.id
    end

    test "a goodwill amount below the constraint minimum renders inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/billing/ledger_entry/new")

      html =
        view
        |> form("#admin-resource-record-form",
          record: %{"wallet_id" => Ecto.UUID.generate(), "amount_cents" => "0"}
        )
        |> render_submit()

      assert html =~ "must be greater than or equal to 1"
      assert has_element?(view, "[data-testid='admin-resource-form']")
    end

    test "?action= on the ledger create mount admits only goodwill", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/billing/ledger_entry/new")

      assert has_element?(view, "[data-testid='admin-resource-input-amount_cents']")

      for crafted <- ["create", "reverse"] do
        assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
                 live(conn, "/admin/resources/billing/ledger_entry/new?action=#{crafted}")

        assert to == "/admin/resources/billing/ledger_entry"
        assert flash["error"] == "That action is not available here."
      end
    end

    test "a mid-session demotion cannot set a waiver", %{
      conn: conn,
      admin: admin
    } do
      wallet = any_wallet!(admin)

      # Mount while the session is still admin (the open tab's
      # posture), demote out-of-band, then submit: the write gate
      # re-resolves and refuses.
      {:ok, view, _html} =
        live(conn, "/admin/resources/billing/wallet/#{wallet.id}/edit?action=set_waiver")

      demote!(admin)

      html =
        view
        |> form("#admin-resource-record-form", record: %{"paywall_waived" => "true"})
        |> render_submit()

      assert html =~ "Your admin access ended. Sign out and sign back in."

      fresh = Ash.get!(Wallet, wallet.id, authorize?: false)
      refute fresh.paywall_waived
    end

    test "non-admins bounce at the route gate on the new domains", %{bare_conn: conn} do
      user =
        User.create!("admin-resources-billing-gate-#{@n}@fluxvale.com", %{}, authorize?: false)

      signed_in = SessionHelpers.sign_in(conn, user)

      for path <- ["/admin/resources/pricing/size", "/admin/resources/billing/wallet/new"] do
        gated = get(signed_in, path)
        assert gated.status == 403
      end
    end
  end

  # -- slice 4: the Catalog rollout (FK links + JSON textareas) ---------------

  describe "the Catalog rollout (slice 4: FK links and JSON textareas)" do
    test "the app index renders the category FK link over the configured columns", %{
      conn: conn,
      admin: admin
    } do
      category = category!(admin)
      _app = app!(admin, category)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app")

      # The configured trim: name, the category link, the created_at
      # pin (the engine's columns contract).
      html = render(view)
      document = LazyHTML.from_fragment(html)

      matches = LazyHTML.query(document, "[data-testid^='admin-resource-col-']")

      rendered =
        for match <- Enum.to_list(matches) do
          [testid] = LazyHTML.attribute(match, "data-testid")
          String.replace_prefix(testid, "admin-resource-col-", "")
        end
        |> MapSet.new()

      assert MapSet.equal?(rendered, MapSet.new(["name", "category_id", "created_at"]))

      link = render(element(view, "a[data-testid='admin-resource-fk-#{category.id}']"))
      assert link =~ category.name
      assert link =~ ~s(href="/admin/resources/catalog/category/#{category.id}")
    end

    test "the app show renders the category FK link with the category's name", %{
      conn: conn,
      admin: admin
    } do
      category = category!(admin)
      app = app!(admin, category)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app/#{app.id}")

      assert has_element?(
               view,
               "a[data-testid='admin-resource-fk-#{category.id}']",
               category.name
             )

      link = render(element(view, "a[data-testid='admin-resource-fk-#{category.id}']"))
      assert link =~ ~s(href="/admin/resources/catalog/category/#{category.id}")
    end

    test "the app_version index renders the app FK link over the configured trim", %{
      conn: conn,
      admin: admin
    } do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)
      version = version!(admin, app, size)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version")

      # The configured trim: exactly version, the app link,
      # published_at, and the created_at pin.
      html = render(view)
      document = LazyHTML.from_fragment(html)

      matches = LazyHTML.query(document, "[data-testid^='admin-resource-col-']")

      rendered =
        for match <- Enum.to_list(matches) do
          [testid] = LazyHTML.attribute(match, "data-testid")
          String.replace_prefix(testid, "admin-resource-col-", "")
        end
        |> MapSet.new()

      assert MapSet.equal?(
               rendered,
               MapSet.new(["version", "app_id", "published_at", "created_at"])
             )

      refute has_element?(view, "[data-testid='admin-resource-col-image']")
      refute has_element?(view, "[data-testid='admin-resource-col-port']")

      # The FK link cell: the app's name, linked to its show page.
      assert has_element?(view, "a[data-testid='admin-resource-fk-#{app.id}']", app.name)

      link = render(element(view, "a[data-testid='admin-resource-fk-#{app.id}']"))
      assert link =~ ~s(href="/admin/resources/catalog/app/#{app.id}")
      assert has_element?(view, "[data-testid='admin-resource-cell-version-#{version.id}']")
    end

    test "the app_version show renders the cross-domain recommended_size link and the app link",
         %{
           conn: conn,
           admin: admin
         } do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)
      version = version!(admin, app, size)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/#{version.id}")

      # The first cross-domain link: catalog → pricing. The size's slug
      # is its label (the registry's heuristic pick).
      assert has_element?(view, "a[data-testid='admin-resource-fk-#{size.id}']", size.slug)

      size_link = render(element(view, "a[data-testid='admin-resource-fk-#{size.id}']"))
      assert size_link =~ ~s(href="/admin/resources/pricing/size/#{size.id}")

      assert has_element?(view, "a[data-testid='admin-resource-fk-#{app.id}']", app.name)

      app_link = render(element(view, "a[data-testid='admin-resource-fk-#{app.id}']"))
      assert app_link =~ ~s(href="/admin/resources/catalog/app/#{app.id}")
    end

    test "app_version :new renders the required JSON textareas", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/new")

      for field <- ["default_env_vars", "configurable_env_vars", "backing_services"] do
        assert has_element?(
                 view,
                 "[data-testid='admin-resource-input-#{field}'] textarea[required]"
               )
      end
    end

    test "a create with JSON-string textarea params decodes and lands on the show page", %{
      conn: conn,
      admin: admin
    } do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/new")

      redirect =
        view
        |> form("#admin-resource-record-form",
          record: %{
            "version" => "9.9.9",
            "image" => "fluxvale/probe:9.9.9",
            "port" => "3000",
            "default_env_vars" => ~s({"A": "1"}),
            "configurable_env_vars" =>
              ~s({"PORT": {"label": "Port", "type": "integer"}, "DATABASE_URL": {"label": "Database URL", "type": "string", "secret": true}}),
            "backing_services" =>
              ~s([{"kind": "postgres", "version": "18", "url_env": "DATABASE_URL"}]),
            "default_cpu_cores" => "0.5",
            "default_memory_mb" => "256",
            "default_storage_gb" => "1",
            "app_id" => app.id,
            "recommended_size_id" => size.id
          }
        )
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = redirect
      assert to =~ "/admin/resources/catalog/app_version/"

      # The JSON text round-tripped into the plain-map shape the
      # composites cast from — this is the decode pipeline's proof.
      segments = String.split(to, "/")
      version_id = List.last(segments)
      version = Ash.get!(AppVersion, version_id, actor: admin)
      assert version.default_env_vars == %{"A" => "1"}

      schema_keys =
        version.configurable_env_vars
        |> Map.keys()
        |> MapSet.new()

      assert MapSet.equal?(schema_keys, MapSet.new(["PORT", "DATABASE_URL"]))

      assert Enum.map(version.backing_services, & &1.url_env) == ["DATABASE_URL"]
    end

    test "a save with already-decoded map textarea params lands the record", %{
      conn: conn,
      admin: admin
    } do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/new")

      redirect =
        render_submit(view, "save", %{
          "record" => %{
            "version" => "9.9.8",
            "image" => "fluxvale/probe:9.9.8",
            "port" => "3000",
            "default_env_vars" => %{"A" => "1"},
            "configurable_env_vars" =>
              ~s({"PORT": {"label": "Port", "type": "integer"}, "DATABASE_URL": {"label": "Database URL", "type": "string", "secret": true}}),
            "backing_services" =>
              ~s([{"kind": "postgres", "version": "18", "url_env": "DATABASE_URL"}]),
            "default_cpu_cores" => "0.5",
            "default_memory_mb" => "256",
            "default_storage_gb" => "1",
            "app_id" => app.id,
            "recommended_size_id" => size.id
          }
        })

      # The textarea params arrive already decoded (a map/list, not JSON
      # text); decode_json_params leaves them untouched and the casts
      # accept them.
      assert {:error, {:live_redirect, %{to: to}}} = redirect
      version_id = to |> String.split("/") |> List.last()
      version = Ash.get!(AppVersion, version_id, actor: admin)
      assert version.default_env_vars == %{"A" => "1"}
    end

    test "invalid JSON in a textarea re-renders with an error, no navigation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/new")

      html =
        view
        |> form("#admin-resource-record-form", record: %{"default_env_vars" => "{oops"})
        |> render_submit()

      assert html =~ "Could not save. Check the errors below."
      assert html =~ "is invalid"
      assert has_element?(view, "[data-testid='admin-resource-form']")

      # The save-failure path keeps the operator's raw text: the failed
      # save merged it into the textarea_text assign before the decode.
      failed_text =
        view
        |> element("[data-testid='admin-resource-input-default_env_vars'] textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert failed_text =~ "{oops"
    end

    test "a validate event carrying an already-decoded map casts clean", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/new")

      html =
        render_change(view, "validate", %{"record" => %{"default_env_vars" => %{"A" => "1"}}})

      # The map-valued param needed no decode and casts clean.
      refute html =~ "is invalid"
      assert has_element?(view, "[data-testid='admin-resource-form']")
    end

    test "the version edit form seeds the JSON textareas with current values", %{
      conn: conn,
      admin: admin
    } do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)
      version = version!(admin, app, size)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/#{version.id}/edit")

      # The :map field seeds as JSON text; read the textarea's text
      # content through LazyHTML so the entity-escaped HTML decodes.
      seeded_value =
        view
        |> element("[data-testid='admin-resource-input-default_env_vars'] textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert seeded_value =~ ~s({"A":"1"})

      # The schema seeds in its in-memory shape and renders serialized
      # through json_safe — atom values as strings; key order is the
      # map's, not a contract.
      schema =
        view
        |> element("[data-testid='admin-resource-input-configurable_env_vars'] textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert schema =~ ~s("type":"integer")
    end

    test "a pristine version edit form shows no field errors — honest seeding, no suppression", %{
      conn: conn,
      admin: admin
    } do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)
      version = version!(admin, app, size)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/#{version.id}/edit")

      # The seed validate runs UNsuppressed: the pristine form renders
      # zero field errors because the seeding casts clean, not because
      # errors are hidden — a stored-data invariant violation would
      # render here.
      html = render(view)
      document = LazyHTML.from_fragment(html)

      errors = LazyHTML.query(document, "[data-testid='admin-resource-form'] p.text-danger")

      assert Enum.to_list(errors) == []
    end

    test "a live validate re-renders the textarea with the operator's text verbatim", %{
      conn: conn,
      admin: admin
    } do
      # The review probe's fixture chain: cpu 1.0 / mem 512 on both
      # sides of the size-match invariant, DATABASE_URL in the schema
      # and in the backing service's url_env.
      size = size!(admin, %{cpu_cores: Decimal.new("1.0"), memory_mb: 512})
      category = category!(admin)
      app = app!(admin, category)

      version =
        version!(admin, app, size, %{
          default_cpu_cores: Decimal.new("1"),
          default_memory_mb: 512
        })

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/#{version.id}/edit")

      # The operator types JSON with their own spacing into BOTH
      # textarea kinds: each field re-renders the text VERBATIM — no
      # cast-value re-serialization, the :map field included (Ash casts
      # the string, but the render reads the raw-text assign). The
      # params decode before validation (the save handler's decode), so
      # a decodable map casts clean at this layer; an undecodable
      # string still shows "is invalid" (the invalid-JSON test).
      typed = ~s({"TYPED": "justnow"})

      render_change(view, "validate", %{
        "record" => %{"configurable_env_vars" => typed, "default_env_vars" => typed}
      })

      re_rendered_composite =
        view
        |> element("[data-testid='admin-resource-input-configurable_env_vars'] textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert re_rendered_composite =~ typed

      re_rendered_map =
        view
        |> element("[data-testid='admin-resource-input-default_env_vars'] textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert re_rendered_map =~ typed

      composite_container =
        render(element(view, "[data-testid='admin-resource-input-configurable_env_vars']"))

      refute composite_container =~ "is invalid"
      assert has_element?(view, "[data-testid='admin-resource-form']")

      # A complete, valid spec decodes before validation: the field
      # casts clean (no "is invalid"), while the textarea still
      # re-renders the operator's text verbatim.
      valid = ~s({"TYPED": {"label": "Typed", "type": "string"}})

      render_change(view, "validate", %{"record" => %{"configurable_env_vars" => valid}})

      composite_container =
        render(element(view, "[data-testid='admin-resource-input-configurable_env_vars']"))

      refute composite_container =~ "is invalid"

      valid_text =
        view
        |> element("[data-testid='admin-resource-input-configurable_env_vars'] textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert valid_text =~ valid
    end

    test "a nil textarea param renders an empty textarea", %{conn: conn, admin: admin} do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)
      version = version!(admin, app, size)

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/#{version.id}/edit")

      render_change(view, "validate", %{"record" => %{"first_run" => nil}})

      first_run =
        view
        |> element("[data-testid='admin-resource-input-first_run'] textarea")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert String.trim(first_run) == ""
    end

    test "the version show renders first_run and oidc_wiring through the inspect fallback", %{
      conn: conn,
      admin: admin
    } do
      size = sized_size!(admin)
      category = category!(admin)
      app = app!(admin, category)

      version =
        version!(admin, app, size, %{
          backing_services: [],
          configurable_env_vars: %{
            "PORT" => %{"label" => "Port", "type" => "integer"},
            "OIDC_ISSUER" => %{"label" => "OIDC issuer", "type" => "string"},
            "OIDC_CLIENT_ID" => %{"label" => "OIDC client id", "type" => "string"},
            "OIDC_CLIENT_SECRET" => %{
              "label" => "OIDC client secret",
              "type" => "string",
              "secret" => true
            }
          },
          first_run: %{
            "pattern" => "first_registered_user_admin",
            "env" => %{},
            "forbidden_env" => [],
            "guidance" => "Claim the first account, then close registration."
          },
          oidc_wiring: %{
            "kind" => "env",
            "issuer_env" => "OIDC_ISSUER",
            "client_id_env" => "OIDC_CLIENT_ID",
            "client_secret_env" => "OIDC_CLIENT_SECRET",
            "pkce" => true
          }
        })

      {:ok, view, _html} = live(conn, "/admin/resources/catalog/app_version/#{version.id}")

      # Composites stay the unknown-type inspect fallback this slice —
      # a JSON-details view is a flagged follow-up.
      assert text_of(
               view,
               "[data-testid='admin-resource-field-first_run'] [data-testid='admin-resource-unknown']"
             ) =~ "first_registered_user_admin"

      assert text_of(
               view,
               "[data-testid='admin-resource-field-oidc_wiring'] [data-testid='admin-resource-unknown']"
             ) =~ "OIDC_CLIENT_SECRET"
    end

    test "a signed-in non-admin gets a bare 403 at the route gate on the Catalog surface", %{
      bare_conn: conn
    } do
      user = User.create!("admin-resources-catalog-#{@n}@fluxvale.com", %{}, authorize?: false)

      conn =
        conn
        |> SessionHelpers.sign_in(user)
        |> get("/admin/resources/catalog/app")

      assert conn.status == 403
    end
  end

  describe "the ?action= selector and field mapping (fabricated entries)" do
    test "the default is the primary action of the type" do
      entry = write_entry(%{})

      assert {:ok, action} = Resources.form_action(entry, :create, nil)
      assert action.name == :create

      assert {:ok, update} = Resources.form_action(entry, :update, nil)
      assert update.name == :update
    end

    test "a registry exclusion empties the set and the mount bounces" do
      read_only = write_entry(%{create_actions: [:create]})

      assert Resources.form_action(read_only, :create, nil) == :error
      assert Resources.form_action(read_only, :create, "create") == :error
    end

    test "the field list maps the accept list to typed inputs" do
      action = Info.action(FeatureFlag, :create)
      fields = Resources.form_fields(FeatureFlag, action)

      assert Enum.map(fields, & &1.name) == [:key, :enabled, :rollout_percentage, :description]

      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name[:key].type == "text"
      assert by_name[:key].required
      assert by_name[:enabled].type == "checkbox"
      assert by_name[:enabled].required == false
      assert by_name[:rollout_percentage].type == "number"
      assert by_name[:rollout_percentage].required == false

      rule_action = Info.action(AccessRule, :create)
      rule_fields = Resources.form_fields(AccessRule, rule_action)
      purpose = Enum.find(rule_fields, &(&1.name == :purpose))

      assert purpose.type == "select"
      assert purpose.options == [{"Auth", "auth"}, {"Feedback", "feedback"}]
      assert purpose.required
    end

    test "an accept name that is not a public attribute is skipped, never guessed at" do
      fields = Resources.form_fields(FeatureFlag, %{accept: [:key, :nope]})

      assert Enum.map(fields, & &1.name) == [:key]
    end

    test "a map-typed attribute maps to the JSON textarea (slice 4's contract)" do
      # Instance.env_vars is the registry's first map-typed attr (slice
      # 5's resource): slice 4's JSON-textarea contract maps it — the
      # type casts from JSON-shaped plain maps and validates through
      # the field errors.
      fields =
        Resources.form_fields(Instance, %{accept: [:name, :env_vars]})

      assert Enum.map(fields, & &1.name) == [:name, :env_vars]
      assert List.last(fields).type == "textarea"
    end
  end

  # Demote out-of-band (the wallet test's posture): User carries no
  # role-write action and Ash.Seed is create-only, so this one
  # precondition rides the data layer directly — tests own their
  # preconditions; the write gate is what the tests pin.
  defp demote!(admin) do
    query = from(u in "users", where: u.id == ^Ecto.UUID.dump!(admin.id))
    {updated, nil} = FluxVale.Repo.update_all(query, set: [platform_role: "user"])
    assert updated == 1
  end
end
