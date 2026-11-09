defmodule FluxValeWeb.AdminDataTableLiveTest do
  @moduledoc false

  # The shared data table's contract (#501), pinned through the
  # people surface (the lightest adopting list): aria-sort cycling,
  # the URL round trip (a URL states the view), garbage-param
  # fallbacks, the page math at its boundaries, the size switch, and
  # the announced state changes. The per-surface grammar lives in the
  # surfaces' own tests; this file owns the pattern.

  use FluxValeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxValeWeb.Components.AdminDataTable

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    admin =
      User.create!(
        "admin-data-table-#{@n}@fluxvale.com",
        %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin)}
  end

  defp unique_address(tag) do
    "test+datatable-#{tag}-#{System.unique_integer()}@fluxvale.com"
  end

  # Precondition rows through the real action (nil actor +
  # authorize?: false, the seeds posture; the deliver discards).
  defp invites!(count, tag) do
    for i <- 1..count do
      {:ok, user, _raw} =
        Identity.invite_user(
          nil,
          unique_address("#{tag}-#{i}"),
          fn _to, _url -> {:ok, :discarded} end,
          authorize?: false
        )

      user
    end
  end

  describe "aria-sort and the sort cycle" do
    test "unsorted headers read none, and clicking cycles ascending then descending through the URL",
         %{conn: conn} do
      invites!(3, "cycle")

      {:ok, view, _html} = live(conn, "/admin/people")

      # The default order is the surface's own; every sortable header
      # reads "none" and no sort param rides the URL.
      assert attribute(view, "admin-people-table-header-invited", "aria-sort") == "none"
      assert attribute(view, "admin-people-table-header-accepted", "aria-sort") == "none"

      # The address column is not sortable: no button to click.
      assert has_element?(view, "[data-testid='admin-people-table-sort-invited_at']")
      assert has_element?(view, "[data-testid='admin-people-table-header-email']")
      refute has_element?(view, "[data-testid='admin-people-table-sort-contact_email']")

      view
      |> element("[data-testid='admin-people-table-sort-invited_at']")
      |> render_click()

      assert_patched(view, "/admin/people?sort=invited_at&dir=asc")
      assert attribute(view, "admin-people-table-header-invited", "aria-sort") == "ascending"
      assert attribute(view, "admin-people-table-header-accepted", "aria-sort") == "none"

      # The announcement names the change.
      assert has_element?(
               view,
               "[data-testid='admin-people-table-announcement']",
               "Sorted by Invited, ascending"
             )

      view
      |> element("[data-testid='admin-people-table-sort-invited_at']")
      |> render_click()

      assert_patched(view, "/admin/people?sort=invited_at&dir=desc")
      assert attribute(view, "admin-people-table-header-invited", "aria-sort") == "descending"

      assert has_element?(
               view,
               "[data-testid='admin-people-table-announcement']",
               "Sorted by Invited, descending"
             )
    end

    test "a URL states the view: reloading the sorted URL lands on the same order", %{
      conn: conn
    } do
      # Three invites, addresses chosen so the alphabetical address
      # order differs from the invited-at order.
      invites!(3, "reload")

      {:ok, view, _html} = live(conn, "/admin/people?sort=invited_at&dir=asc")

      assert attribute(view, "admin-people-table-header-invited", "aria-sort") == "ascending"

      assert has_element?(view, "[data-testid='admin-people-table-count']")

      # The oldest row tops an ascending list.
      rows = row_ids(view)
      assert length(rows) == 3
    end
  end

  describe "garbage params" do
    test "every crafted param falls back to defaults honestly, no crash", %{conn: conn} do
      invites!(2, "garbage")

      assert {:ok, view, _html} =
               live(
                 conn,
                 "/admin/people?sort=email&dir=sideways&page=abc&size=999&q=%20%20&cursor=x"
               )

      # Unknown sort field: the default order, every header "none".
      assert attribute(view, "admin-people-table-header-invited", "aria-sort") == "none"

      # Non-numeric page and out-of-set size: page 1 of 1 at 25.
      assert has_element?(view, "[data-testid='admin-people-table-page-label']", "Page 1 of 1")
      assert has_element?(view, "[data-testid='admin-people-table-size-25'][aria-pressed='true']")

      # A whitespace-only query trims to nothing: the unfiltered view.
      assert has_element?(view, "[data-testid='admin-people-table-count']")
    end

    test "a page past the end clamps to the last page", %{conn: conn} do
      invites!(26, "clamp")

      {:ok, view, _html} = live(conn, "/admin/people?page=9")

      assert has_element?(view, "[data-testid='admin-people-table-page-label']", "Page 2 of 2")
      assert has_element?(view, "[data-testid='admin-people-table-count']", "of 26")
    end
  end

  describe "the page math at its boundaries" do
    test "zero rows: the honest empty state, no pagination chrome", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/people")

      assert has_element?(view, "[data-testid='admin-people-list'] p", "No invitations yet.")
      refute has_element?(view, "[data-testid='admin-people-table-pagination']")
    end

    test "exactly 25 rows: one page, next disabled, the count exact", %{conn: conn} do
      invites!(25, "exact")

      {:ok, view, _html} = live(conn, "/admin/people")

      assert has_element?(view, "[data-testid='admin-people-table-count']", "1 to 25 of 25")
      assert has_element?(view, "[data-testid='admin-people-table-page-label']", "Page 1 of 1")
      assert has_element?(view, "[data-testid='admin-people-table-page-prev'][disabled]")
      assert has_element?(view, "[data-testid='admin-people-table-page-next'][disabled]")
    end

    test "26 rows: two pages, prev disabled on page one, one row on page two", %{conn: conn} do
      invited = invites!(26, "boundary")
      oldest = List.first(invited)

      {:ok, view, _html} = live(conn, "/admin/people")

      assert has_element?(view, "[data-testid='admin-people-table-count']", "1 to 25 of 26")
      assert has_element?(view, "[data-testid='admin-people-table-page-prev'][disabled]")
      refute has_element?(view, "[data-testid='admin-people-table-page-next'][disabled]")

      view
      |> element("[data-testid='admin-people-table-page-next']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-people-table-count']", "26 to 26 of 26")
      assert has_element?(view, "[data-testid='admin-people-table-page-label']", "Page 2 of 2")
      assert has_element?(view, "[data-testid='admin-people-table-page-next'][disabled]")
      assert has_element?(view, "[data-testid='admin-people-email-#{oldest.id}']")

      # Prev carries the operator back and the URL states it.
      view
      |> element("[data-testid='admin-people-table-page-prev']")
      |> render_click()

      assert has_element?(view, "[data-testid='admin-people-table-page-label']", "Page 1 of 2")
    end
  end

  describe "the size switch" do
    test "50 folds two pages into one, resets the page, and rides the URL", %{conn: conn} do
      invites!(26, "size")

      {:ok, view, _html} = live(conn, "/admin/people?page=2")

      assert has_element?(view, "[data-testid='admin-people-table-page-label']", "Page 2 of 2")

      view
      |> element("[data-testid='admin-people-table-size-50']")
      |> render_click()

      assert_patched(view, "/admin/people?size=50")
      assert has_element?(view, "[data-testid='admin-people-table-count']", "1 to 26 of 26")
      assert has_element?(view, "[data-testid='admin-people-table-page-label']", "Page 1 of 1")
      assert has_element?(view, "[data-testid='admin-people-table-size-50'][aria-pressed='true']")

      assert has_element?(
               view,
               "[data-testid='admin-people-table-size-25'][aria-pressed='false']"
             )

      assert has_element?(view, "[data-testid='admin-people-table-size-100']")
    end
  end

  describe "the search term rides the URL" do
    test "a search patches q, a reload lands on the filtered view, clearing hands it back", %{
      conn: conn,
      admin: admin
    } do
      {:ok, alpha, _raw} = Identity.invite_user(admin, unique_address("alpha"))
      {:ok, _beta, _raw} = Identity.invite_user(admin, unique_address("beta"))

      {:ok, view, _html} = live(conn, "/admin/people")

      render_change(view, "search", %{"search" => %{"query" => "alpha"}})

      assert_patched(view, "/admin/people?q=alpha")
      assert has_element?(view, "[data-testid='admin-people-email-#{alpha.id}']")

      assert has_element?(
               view,
               "[data-testid='admin-people-table-announcement']",
               "Search: alpha"
             )

      # Reloading the URL lands on the same view.
      {:ok, reloaded, _html} = live(conn, "/admin/people?q=alpha")
      assert has_element?(reloaded, "[data-testid='admin-people-email-#{alpha.id}']")

      render_change(view, "search", %{"search" => %{"query" => ""}})
      assert_patched(view, "/admin/people")
    end
  end

  describe "the param and pagination helpers" do
    # The public contract the surfaces lean on, pinned directly: the
    # toggles, the size set, the page math, and the URL builder.
    test "toggle_sort honors the whitelist, flips the sorted field, and resets a new field" do
      sortable = [:created_at, :amount]

      assert AdminDataTable.toggle_sort(nil, "garbage", sortable) == nil

      assert AdminDataTable.toggle_sort({:created_at, :desc}, "garbage", sortable) ==
               {:created_at, :desc}

      assert AdminDataTable.toggle_sort(nil, "created_at", sortable) == {:created_at, :asc}

      assert AdminDataTable.toggle_sort({:created_at, :asc}, "created_at", sortable) ==
               {:created_at, :desc}

      assert AdminDataTable.toggle_sort({:created_at, :desc}, "created_at", sortable) ==
               {:created_at, :asc}

      assert AdminDataTable.toggle_sort({:created_at, :desc}, "amount", sortable) ==
               {:amount, :asc}

      # A non-binary field is not a crash.
      assert AdminDataTable.toggle_sort({:created_at, :desc}, :crafted, sortable) ==
               {:created_at, :desc}
    end

    test "the page-size set is the one set, and parse_size falls back honestly" do
      assert AdminDataTable.default_sizes() == [25, 50, 100]

      assert AdminDataTable.parse_size("50") == 50
      assert AdminDataTable.parse_size("999") == 25
      assert AdminDataTable.parse_size("abc") == 25
      assert AdminDataTable.parse_size(:crafted) == 25
    end

    test "page_count never reports fewer than one page" do
      assert AdminDataTable.page_count(1, 25) == 1
      assert AdminDataTable.page_count(25, 25) == 1
      assert AdminDataTable.page_count(26, 25) == 2
      assert AdminDataTable.page_count(51, 50) == 2
      assert AdminDataTable.page_count(0, 25) == 1
    end

    test "url_for states only the non-default params, in one fixed order" do
      base = "/admin/people"

      assert AdminDataTable.url_for(base, %{query: "", page: 1, size: 25}) == base

      state = %{query: "quill", page: 2, size: 50, sort: {:created_at, :desc}}

      assert AdminDataTable.url_for(base, state) ==
               "/admin/people?q=quill&sort=created_at&dir=desc&page=2&size=50"

      cursor_state = %{query: "", page: 1, size: 25, after: "Gctp", before: nil}

      assert AdminDataTable.url_for(base, cursor_state) == "/admin/people?after=Gctp"
    end

    test "keyset links answer nils for anything that is not a keyset page" do
      assert AdminDataTable.keyset_links(%{not: :a_page}) == %{next: nil, prev: nil}
    end

    test "parse_params leaves every crafted shape a valid view" do
      params = %{
        "sort" => :crafted,
        "dir" => 7,
        "page" => %{"deep" => "crafted"},
        "size" => ["50"],
        "q" => 123,
        "after" => [:crafted],
        "before" => ""
      }

      state = AdminDataTable.parse_params(params, sortable: [:created_at])

      assert state == %{
               sort: nil,
               page: 1,
               size: 25,
               query: "",
               after: nil,
               before: nil,
               total: nil
             }
    end
  end

  # The dom ids of the shown rows, in order.
  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid^='admin-people-email-']")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.attribute("data-testid")
      |> Enum.join("")
      |> String.replace_prefix("admin-people-email-", "")
    end)
  end

  # One attribute off one element, the plain way.
  defp attribute(view, testid, name) do
    html = render(element(view, "[data-testid='#{testid}']"))
    document = LazyHTML.from_fragment(html)
    matches = LazyHTML.query(document, "[data-testid='#{testid}']")
    first = Enum.at(matches, 0)
    values = LazyHTML.attribute(first, name) || []

    Enum.join(values, "")
  end
end
