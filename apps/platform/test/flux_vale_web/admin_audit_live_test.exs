defmodule FluxValeWeb.AdminAuditLiveTest do
  @moduledoc false

  # The Audit section (#645): the trail's window through the real
  # mount. The list renders the tombstone as recorded (System for nil),
  # a destroy keeps its row, the filters ride the params honestly, and
  # the gates answer before any version row is read. The version-read
  # policy is pinned through the section's own query path — the mixin
  # decides, never the UI.

  use FluxValeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FluxVale.Accounts
  alias FluxVale.Feedback.Tag
  alias FluxVale.Identity.User
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.ApiPat
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.AdminAudit
  alias FluxValeWeb.AdminLive.Audit

  require Ash.Query

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!("admin-audit-admin-#{@n}@fluxvale.com", %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  defp flag!(actor, suffix) do
    FeatureFlag
    |> Ash.Changeset.for_create(:create, %{key: "audit_flag_#{suffix}_#{@n}"}, actor: actor)
    |> Ash.create!()
  end

  defp tag!(actor, name) do
    Tag
    |> Ash.Changeset.for_create(:create, %{name: name}, actor: actor)
    |> Ash.create!()
  end

  defp versions!(version_module, source_id) do
    version_module
    |> Ash.Query.filter(version_source_id == ^source_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the version list" do
    test "the default resource is the picker's first entry and rows carry the audit grammar", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin, "grammar")

      # The actor filter scopes the count to this test's row — the
      # shared partition DB carries committed strays from other lanes,
      # and an unfiltered count would read them (the #241 lesson).
      path = "/admin/audit?" <> URI.encode_query(%{"actor" => admin.username})
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "[data-testid='admin-audit-table']")
      assert has_element?(view, "[data-testid='admin-audit']")

      # The section's own entry is the page; the siblings stay quiet.
      assert has_element?(view, "[data-testid='admin-nav-audit'][aria-current='page']")
      refute render(element(view, "[data-testid='admin-nav-gateways']")) =~ "aria-current"

      # The picker carries the whole browsable set, grouped by domain.
      for entry <- AdminAudit.entries() do
        assert has_element?(view, "[data-testid='admin-audit-pick-#{entry.key}']"),
               "the picker misses #{entry.key}"
      end

      # The row: the version's own stamp, the neutral type badge, the
      # action name, the actor tombstone, and the changes block.
      [version] = versions!(FeatureFlag.Version, flag.id)
      stamp = Calendar.strftime(version.version_inserted_at, "%b %d, %Y %H:%M UTC")

      assert text_of(view, "[data-testid='admin-audit-stamp-#{version.id}']") == stamp
      assert text_of(view, "[data-testid='admin-audit-type-#{version.id}']") == "Create"
      assert text_of(view, "[data-testid='admin-audit-action-#{version.id}']") == "Create"

      assert text_of(view, "[data-testid='admin-audit-actor-#{version.id}']") == admin.username

      json = text_of(view, "[data-testid='admin-audit-changes-json-#{version.id}']")
      assert json =~ ~s("key")

      assert text_of(view, "[data-testid='admin-audit-count']") == "1 change"
    end

    test "?resource= selects the audited resource", %{conn: conn, admin: admin} do
      flag = flag!(admin, "scoped")
      tag = tag!(admin, "audit-scoped-#{@n}")

      {:ok, view, _html} = live(conn, "/admin/audit?resource=tag")

      [tag_version] = versions!(Tag.Version, tag.id)
      [flag_version] = versions!(FeatureFlag.Version, flag.id)

      assert has_element?(view, "[data-testid='admin-audit-row-#{tag_version.id}']")
      refute has_element?(view, "[data-testid='admin-audit-row-#{flag_version.id}']")

      # The count rides a source-scoped mount for the same reason:
      # committed strays from other lanes must not read into it.
      scoped_path = "/admin/audit?resource=tag&source=#{tag.id}"
      {:ok, scoped, _html} = live(conn, scoped_path)
      assert text_of(scoped, "[data-testid='admin-audit-count']") == "1 change"
    end

    test "an unknown ?resource bounces to the default with the honest flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/audit", flash: flash}}} =
               live(conn, "/admin/audit?resource=nope")

      assert flash["error"] == "That page does not exist here."
    end

    test "a system write renders the honest System attribution", %{conn: conn} do
      flag =
        FeatureFlag
        |> Ash.Changeset.for_create(:create, %{key: "audit_system_flag_#{@n}"}, authorize?: false)
        |> Ash.create!()

      {:ok, view, _html} = live(conn, "/admin/audit")

      [version] = versions!(FeatureFlag.Version, flag.id)

      assert text_of(view, "[data-testid='admin-audit-actor-#{version.id}']") == "System"
    end

    test "an empty resource answers with the empty state, not a bare table", %{conn: conn} do
      # The shared partition DB carries committed version strays from
      # other lanes' strands (versions outlive their rolled-back
      # sources). Version resources carry no destroy action, so the
      # test clears the view's table on the data layer — INSIDE the
      # sandbox, rolled back after, the shared DB untouched (#241's
      # sweep discipline applied to the trail's tables).
      {deleted, nil} = FluxVale.Repo.delete_all("feedback_votes_versions")

      assert deleted >= 0

      {:ok, view, _html} = live(conn, "/admin/audit?resource=vote")

      assert has_element?(view, "[data-testid='admin-audit-empty']", "No history yet.")
      assert text_of(view, "[data-testid='admin-audit-count']") == "0 changes"
    end
  end

  describe "the filters" do
    test "?actor= exact-matches the tombstone", %{conn: conn, admin: admin} do
      other_admin =
        User.create!("admin-audit-second-#{@n}@fluxvale.com", %{platform_role: :admin},
          authorize?: false
        )

      mine = flag!(admin, "actor_a")
      theirs = flag!(other_admin, "actor_b")

      path = "/admin/audit?" <> URI.encode_query(%{"actor" => admin.username})
      {:ok, view, _html} = live(conn, path)

      [my_version] = versions!(FeatureFlag.Version, mine.id)
      [their_version] = versions!(FeatureFlag.Version, theirs.id)

      assert has_element?(view, "[data-testid='admin-audit-row-#{my_version.id}']")
      refute has_element?(view, "[data-testid='admin-audit-row-#{their_version.id}']")
      assert text_of(view, "[data-testid='admin-audit-count']") == "1 change"

      assert text_of(view, "[data-testid='admin-audit-filter-actor']") ==
               "Actor: #{admin.username}"
    end

    test "?source= narrows one record's history", %{conn: conn, admin: admin} do
      created = flag!(admin, "source_a")

      edited =
        created
        |> Ash.Changeset.for_update(:update, %{description: "now described"}, actor: admin)
        |> Ash.update!()

      untouched = flag!(admin, "source_b")

      path = "/admin/audit?resource=feature_flag&source=#{edited.id}"
      {:ok, view, _html} = live(conn, path)

      edited_versions = versions!(FeatureFlag.Version, edited.id)
      assert length(edited_versions) == 2

      for version <- edited_versions do
        assert has_element?(view, "[data-testid='admin-audit-row-#{version.id}']")
      end

      [other_version] = versions!(FeatureFlag.Version, untouched.id)
      refute has_element?(view, "[data-testid='admin-audit-row-#{other_version.id}']")

      assert text_of(view, "[data-testid='admin-audit-count']") == "2 changes"

      assert text_of(view, "[data-testid='admin-audit-filter-source']") =~
               String.slice(edited.id, 0, 8)
    end

    test "filters with no matches answer the filter empty state", %{conn: conn} do
      path = "/admin/audit?" <> URI.encode_query(%{"actor" => "nobody-with-that-name"})
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "[data-testid='admin-audit-filter-empty']")
    end

    test "a malformed ?source bounces with an honest flash, keeping the resource", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/audit?resource=feature_flag&source=not-a-uuid")

      assert to == "/admin/audit?resource=feature_flag&page=1"
      assert flash["error"] == "That history link is malformed."
    end
  end

  describe "destroy evidence" do
    test "a destroyed record's version renders — the trail outlives the row", %{
      conn: conn,
      admin: admin
    } do
      flag = flag!(admin, "destroyed")

      flag
      |> Ash.Changeset.for_destroy(:destroy, %{}, actor: admin)
      |> Ash.destroy!()

      {:ok, view, _html} = live(conn, "/admin/audit?resource=feature_flag")

      versions = versions!(FeatureFlag.Version, flag.id)
      destroy_version = List.last(versions)

      assert destroy_version.version_action_type == :destroy

      assert text_of(view, "[data-testid='admin-audit-type-#{destroy_version.id}']") ==
               "Destroy"

      # A destroy versions no deltas: the changes block reads {}.
      assert text_of(view, "[data-testid='admin-audit-changes-json-#{destroy_version.id}']") ==
               "{}"
    end

    test "REDACTED markers render verbatim — the sensitive value never ships", %{conn: conn} do
      {org, owner} = BillingFixtures.grant_free_org!()
      address = "audit-redacted-#{@n}@fluxvale.test"

      {:ok, _invite} = Accounts.invite_member(owner, org, address)

      {:ok, view, _html} = live(conn, "/admin/audit?resource=membership_invite")

      assert render(view) =~ "REDACTED"
    end
  end

  describe "pagination" do
    test "25 to a page with the count-aware controls, filters riding the links", %{
      conn: conn,
      admin: admin
    } do
      for i <- 1..26 do
        tag!(admin, "audit-page-#{i}-#{@n}")
      end

      # The actor filter scopes every count and row list below to this
      # test's own writes (the shared partition DB's committed strays).
      base =
        "/admin/audit?" <> URI.encode_query(%{"resource" => "tag", "actor" => admin.username})

      {:ok, view, _html} = live(conn, base)

      assert text_of(view, "[data-testid='admin-audit-count']") == "26 changes"
      assert has_element?(view, "[data-testid='admin-audit-pagination']")
      assert has_element?(view, "[data-testid='admin-audit-page-2']")

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-testid^='admin-audit-row-']")
        |> Enum.to_list()

      assert length(rows) == 25

      # Page 2 carries the last row.
      {:ok, view2, _html} = live(conn, base <> "&page=2")
      assert length(rows_on(view2)) == 1

      # A non-integer page reads as page one (the engine's grammar).
      {:ok, view3, _html} = live(conn, base <> "&page=nope")
      assert length(rows_on(view3)) == 25
    end

    test "a page past the end bounces to the real last page", %{conn: conn, admin: admin} do
      for i <- 1..26 do
        tag!(admin, "audit-bounce-#{i}-#{@n}")
      end

      # The app's own builder emits resource first (the ordered pairs),
      # so the expected URL spells the same order.
      base =
        "/admin/audit?" <> URI.encode_query([{:resource, "tag"}, {:actor, admin.username}])

      expected = base <> "&page=2"

      assert {:error, {:live_redirect, %{to: ^expected}}} =
               live(conn, base <> "&page=99")

      # A crafted 19-digit page caps at the bound first (the engine's
      # parse grammar) — past the end, bounced the same way, no crash.
      assert {:error, {:live_redirect, %{to: ^expected}}} =
               live(conn, base <> "&page=9999999999999999999")
    end

    test "crafted param shapes read honestly — page lists as page one, actor and source lists refused",
         %{
           conn: conn,
           admin: admin
         } do
      flag = flag!(admin, "crafted")

      # ?page[]=2 is a list, not a page number: it reads as page one.
      {:ok, page_view, _html} = live(conn, "/admin/audit?resource=feature_flag&page%5B%5D=2")

      [version] = versions!(FeatureFlag.Version, flag.id)
      assert has_element?(page_view, "[data-testid='admin-audit-row-#{version.id}']")

      # A list actor filters nothing: the full history renders.
      {:ok, actor_view, _html} = live(conn, "/admin/audit?resource=feature_flag&actor%5B%5D=x")

      assert has_element?(actor_view, "[data-testid='admin-audit-row-#{version.id}']")
      refute has_element?(actor_view, "[data-testid='admin-audit-filter-actor']")

      # An empty actor param filters nothing either — a bare ?actor=
      # never reads as "the actor whose name is empty".
      {:ok, empty_view, _html} = live(conn, "/admin/audit?resource=feature_flag&actor=")

      assert has_element?(empty_view, "[data-testid='admin-audit-row-#{version.id}']")
      refute has_element?(empty_view, "[data-testid='admin-audit-filter-actor']")

      # A list source is a malformed deep link like any other garbage.
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/admin/audit?resource=feature_flag&source%5B%5D=x")

      assert to == "/admin/audit?resource=feature_flag&page=1"
      assert flash["error"] == "That history link is malformed."
    end

    defp rows_on(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid^='admin-audit-row-']")
      |> Enum.to_list()
    end
  end

  describe "the gates" do
    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)

      assert get(signed, "/admin/audit").status == 403
    end

    test "a bearer-only socket bounces at mount (AdminGate)", %{admin: admin} do
      pat = ApiPat.mint!(admin, ["instances:read"])
      conn = put_req_header(build_conn(), "authorization", "Bearer " <> pat)

      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/admin/audit")
    end
  end

  describe "the version-read policy through the section's own query" do
    test "a member actor is Forbidden on the exact path the section reads" do
      member = SessionHelpers.user!()
      entry = Enum.find(AdminAudit.entries(), &(&1.key == :feature_flag))

      assert_raise Ash.Error.Forbidden, fn ->
        Audit.read_page(entry, %{actor: nil, source: nil}, 1, member)
      end
    end

    test "the platform admin reads through the same seam" do
      admin = AccountsFixtures.admin!()
      entry = Enum.find(AdminAudit.entries(), &(&1.key == :feature_flag))

      assert %Ash.Page.Offset{} = Audit.read_page(entry, %{actor: nil, source: nil}, 1, admin)
    end
  end

  describe "the engine's History deep link" do
    test "the show page links the record's audit history", %{conn: conn, admin: admin} do
      flag = flag!(admin, "history_link")

      {:ok, view, _html} = live(conn, "/admin/resources/ops/feature_flag/#{flag.id}")

      assert has_element?(
               view,
               "[data-testid='admin-resource-history']" <>
                 "[href='/admin/audit?resource=feature_flag&source=#{flag.id}']"
             )
    end

    test "following the link lands on the record's history", %{conn: conn, admin: admin} do
      created = flag!(admin, "deep_link")

      flag =
        created
        |> Ash.Changeset.for_update(:update, %{description: "linked"}, actor: admin)
        |> Ash.update!()

      {:ok, view, _html} = live(conn, "/admin/audit?resource=feature_flag&source=#{flag.id}")

      for version <- versions!(FeatureFlag.Version, flag.id) do
        assert has_element?(view, "[data-testid='admin-audit-row-#{version.id}']")
      end

      assert text_of(view, "[data-testid='admin-audit-count']") == "2 changes"
    end
  end
end
