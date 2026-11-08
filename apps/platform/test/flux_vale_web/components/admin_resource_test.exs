defmodule FluxValeWeb.Components.AdminResourceTest do
  @moduledoc false

  # The console renderer's contract (#595): the shape mapping over
  # real resource attributes, typed value rendering per the plan's
  # contracts table (including the unknown-type fallback later slices
  # lean on), the label derivations, and the pagination math.
  #
  # No DB: everything here renders components or calls pure helpers
  # against compiled resource modules.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Ash.Resource.Info
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.FeatureFlag
  alias FluxValeWeb.AdminResource

  defp attr(module, name) do
    attrs = Info.attributes(module)
    Enum.find(attrs, &(&1.name == name))
  end

  defp text_of(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  describe "the shape mapping (the plan's rendering table)" do
    test "uuid types are uuid" do
      id = attr(FeatureFlag, :id)
      assert AdminResource.shape(id) == :uuid
    end

    test "string and ci_string are string — ci renders as plain text" do
      key = attr(FeatureFlag, :key)
      assert AdminResource.shape(key) == :string

      domain = attr(AccessRule, :domain)
      assert AdminResource.shape(domain) == :string

      email = attr(AccessRule, :email)
      assert AdminResource.shape(email) == :string
    end

    test "integer and boolean keep their shapes" do
      rollout = attr(FeatureFlag, :rollout_percentage)
      assert AdminResource.shape(rollout) == :integer

      enabled = attr(FeatureFlag, :enabled)
      assert AdminResource.shape(enabled) == :boolean
    end

    test "an atom with a one_of constraint is an enum" do
      purpose = attr(AccessRule, :purpose)
      assert AdminResource.shape(purpose) == :enum
    end

    test "anything unrecognized is the fallback" do
      assert AdminResource.shape(%{type: Ash.Type.Date}) == :unknown
      assert AdminResource.shape(%{type: Ash.Type.Atom, constraints: []}) == :unknown
      assert AdminResource.shape(%{type: SomeUnmappedType}) == :unknown
    end
  end

  describe "value rendering" do
    test "a uuid index cell is the first eight characters, mono, full value in the title" do
      uuid = "01a1b89f-0c37-7660-8970-2b93c7181a59"

      html = render_component(&AdminResource.value/1, shape: :uuid, value: uuid, variant: :index)

      assert text_of(html, "span") == String.slice(uuid, 0, 8)
      assert html =~ ~s(title="#{uuid}")
      assert html =~ "font-mono"
    end

    test "a uuid show cell is the full value with a copy affordance" do
      uuid = "01a1b89f-0c37-7660-8970-2b93c7181a59"

      html =
        render_component(&AdminResource.value/1,
          shape: :uuid,
          value: uuid,
          variant: :show,
          id: "copy-me"
        )

      assert html =~ uuid
      assert html =~ ~s(data-copy-value="#{uuid}")
    end

    test "a string index cell truncates with the full value in the title" do
      long = String.duplicate("w", 80)

      html =
        render_component(&AdminResource.value/1, shape: :string, value: long, variant: :index)

      assert text_of(html, "span") == long
      assert html =~ "truncate"
      assert html =~ ~s(title="#{long}")
    end

    test "an integer index cell is right-aligned mono" do
      html = render_component(&AdminResource.value/1, shape: :integer, value: 42, variant: :index)

      assert text_of(html, "span") == "42"
      assert html =~ "justify-end"
      assert html =~ "font-mono"
    end

    test "booleans read Yes or No" do
      yes = render_component(&AdminResource.value/1, shape: :boolean, value: true)
      no = render_component(&AdminResource.value/1, shape: :boolean, value: false)

      assert text_of(yes, "span") == "Yes"
      assert text_of(no, "span") == "No"
    end

    test "an enum renders a humanized neutral badge" do
      html = render_component(&AdminResource.value/1, shape: :enum, value: :feedback)

      assert text_of(html, "[data-testid='admin-resource-enum']") == "Feedback"
    end

    test "a datetime index cell is the stamp shape, full value in the title" do
      stamp = ~U[2026-11-08 09:30:00Z]

      html =
        render_component(&AdminResource.value/1, shape: :datetime, value: stamp, variant: :index)

      assert text_of(html, "[data-testid='admin-resource-datetime']") == "Nov 08, 2026"
      assert html =~ ~s(title="#{DateTime.to_string(stamp)}")
    end

    test "a datetime show cell adds the UTC time of day" do
      stamp = ~U[2026-11-08 09:30:00Z]

      html =
        render_component(&AdminResource.value/1, shape: :datetime, value: stamp, variant: :show)

      assert text_of(html, "[data-testid='admin-resource-datetime']") == "Nov 08, 2026 09:30 UTC"
    end

    test "nil reads as Not set in either variant" do
      for variant <- [:index, :show] do
        html =
          render_component(&AdminResource.value/1, shape: :string, value: nil, variant: variant)

        assert text_of(html, "[data-testid='admin-resource-empty-value']") == "Not set"
      end
    end

    test "the unknown-type fallback inspects the value in mono" do
      html =
        render_component(&AdminResource.value/1,
          shape: :unknown,
          value: %{surprise: :map},
          variant: :show
        )

      assert text_of(html, "[data-testid='admin-resource-unknown']") == "%{surprise: :map}"
      assert html =~ "font-mono"
    end
  end

  describe "labels" do
    test "attribute names read as capitalized words" do
      assert AdminResource.label(:rollout_percentage) == "Rollout percentage"
      assert AdminResource.label(:created_at) == "Created at"
      assert AdminResource.label("domain") == "Domain"
    end

    test "id stays the initialism operators read" do
      assert AdminResource.label(:id) == "ID"
    end
  end

  describe "pagination math" do
    test "total pages come from the count and the page size, never below one" do
      assert AdminResource.total_pages(26, 25) == 2
      assert AdminResource.total_pages(25, 25) == 1
      assert AdminResource.total_pages(24, 25) == 1
      assert AdminResource.total_pages(0, 25) == 1
    end

    test "small totals show every page" do
      assert AdminResource.page_window(1, 1) == [1]
      assert AdminResource.page_window(2, 3) == [1, 2, 3]
      assert AdminResource.page_window(3, 7) == [1, 2, 3, 4, 5, 6, 7]
    end

    test "large totals keep first, last, and the current window — adjacent pages join without a gap" do
      assert AdminResource.page_window(1, 8) == [1, 2, 3, :gap, 8]
      assert AdminResource.page_window(2, 8) == [1, 2, 3, :gap, 8]
      assert AdminResource.page_window(3, 8) == [1, 2, 3, 4, :gap, 8]
      assert AdminResource.page_window(4, 9) == [1, :gap, 3, 4, 5, :gap, 9]
      assert AdminResource.page_window(7, 9) == [1, :gap, 6, 7, 8, 9]
      assert AdminResource.page_window(9, 9) == [1, :gap, 7, 8, 9]
    end
  end

  describe "the pagination controls" do
    test "one page renders no controls — a lone number is not a control" do
      assert render_component(&AdminResource.pagination/1, current: 1, total: 1, path: "/x") == ""
    end

    test "prev and next disable at the ends, numbers carry the page" do
      html =
        render_component(&AdminResource.pagination/1,
          current: 1,
          total: 3,
          path: "/admin/resources/ops/feature_flag"
        )

      assert html =~ ~s(aria-disabled="true")
      assert html =~ ~s(href="/admin/resources/ops/feature_flag?page=2")
      assert html =~ ~s(href="/admin/resources/ops/feature_flag?page=3")
    end

    test "the current page carries the page mark and the window elides" do
      html =
        render_component(&AdminResource.pagination/1,
          current: 4,
          total: 9,
          path: "/x"
        )

      current = text_of(html, "[data-testid='admin-resource-page-4']")
      assert current == "4"
      assert html =~ ~s(aria-current="page")

      assert html =~ ~s(href="/x?page=1")
      assert html =~ ~s(href="/x?page=9")
      assert html =~ "…"
    end
  end
end
