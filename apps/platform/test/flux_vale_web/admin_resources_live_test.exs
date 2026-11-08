defmodule FluxValeWeb.AdminResourcesLiveTest do
  @moduledoc false

  # The generic resource console's read path (#595 slice 1, proven on
  # Ops): the picker pages, the index with typed cells and pagination,
  # the actor-safe show page, the honest 404s for unknown segments,
  # and BOTH gates (the route pipeline and the AdminGate socket
  # re-check). Write mounts are slice 2 — none exist here.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ash.Resource.Info
  alias FluxVale.Identity.User
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.SessionHelpers
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

  describe "route resolution honesty" do
    test "an unknown domain segment bounces to the landing with an honest flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources"}}} =
               live(conn, "/admin/resources/nope")
    end

    test "an unknown resource segment bounces the same way", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/resources"}}} =
               live(conn, "/admin/resources/ops/nope")
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
      pat = ApiPat.mint!(admin.email, ["instances:read"])
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(conn, "/admin/resources/ops/feature_flag")
    end
  end
end
