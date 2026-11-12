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
  alias FluxVale.Feedback.Post
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.FeatureFlag
  alias FluxValeWeb.AdminLive.Resources
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
      assert AdminResource.shape(%{type: Ash.Type.UUID}) == :uuid
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

    test "any utc datetime precision is datetime" do
      created = attr(FeatureFlag, :created_at)
      assert AdminResource.shape(created) == :datetime
      assert AdminResource.shape(%{type: Ash.Type.UtcDatetime}) == :datetime
    end

    test "an atom with a one_of constraint is an enum" do
      purpose = attr(AccessRule, :purpose)
      assert AdminResource.shape(purpose) == :enum
    end

    test "decimal is its own shape (slice 3: Size cpu_cores)" do
      cpu = attr(FluxVale.Pricing.Size, :cpu_cores)
      assert AdminResource.shape(cpu) == :decimal
      assert AdminResource.shape(%{type: Ash.Type.Decimal}) == :decimal
    end

    test "a custom enum type (values/0) is an enum — EntryType and EntryReason" do
      type = attr(FluxVale.Billing.LedgerEntry, :type)
      reason = attr(FluxVale.Billing.LedgerEntry, :reason)

      assert AdminResource.shape(type) == :enum
      assert AdminResource.shape(reason) == :enum
    end

    test "a map attr is the map shape (slice 5: Instance env_vars)" do
      env_vars = attr(FluxVale.Infrastructure.Instance, :env_vars)

      assert AdminResource.shape(env_vars) == :map
      assert AdminResource.shape(%{type: Ash.Type.Map}) == :map
    end

    test "anything unrecognized is the fallback" do
      # Atom module types reach the enum check first (the is_atom
      # clause): an unmapped module answers through it, while a tuple
      # type (arrays ride {:array, _}) is the true catch-all.
      assert AdminResource.shape(%{type: Ash.Type.Date}) == :unknown
      assert AdminResource.shape(%{type: Ash.Type.Atom, constraints: []}) == :unknown
      assert AdminResource.shape(%{type: SomeUnmappedType}) == :unknown
      assert AdminResource.shape(%{type: {:array, Ash.Type.String}}) == :unknown
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

    test "an integer show cell is mono in full" do
      html = render_component(&AdminResource.value/1, shape: :integer, value: 42, variant: :show)

      assert text_of(html, "span") == "42"
      assert html =~ "font-mono"
      refute html =~ "justify-end"
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

    test "a custom enum value badges exactly like a one_of atom" do
      html = render_component(&AdminResource.value/1, shape: :enum, value: :credit)

      assert text_of(html, "[data-testid='admin-resource-enum']") == "Credit"
    end

    test "a map show value is a JSON details block with pretty JSON" do
      html =
        render_component(&AdminResource.value/1,
          shape: :map,
          value: %{"GREETING" => "hello", "PORT" => "3000"},
          variant: :show
        )

      details = "[data-testid='admin-resource-json']"

      assert text_of(html, "#{details} summary") == "JSON"
      assert text_of(html, "#{details} pre") =~ ~s("GREETING": "hello")
      assert text_of(html, "#{details} pre") =~ "\n"
    end

    test "an unencodable map falls back to inspect" do
      html =
        render_component(&AdminResource.value/1,
          shape: :map,
          value: %{pid: self(), tuple: {:a, 1}},
          variant: :show
        )

      text = text_of(html, "[data-testid='admin-resource-json'] pre")
      assert text =~ "pid"
      assert text =~ "{:a, 1}"
    end

    test "a map index value is the neutral map badge" do
      html =
        render_component(&AdminResource.value/1,
          shape: :map,
          value: %{"GREETING" => "hello"},
          variant: :index
        )

      assert text_of(html, "[data-testid='admin-resource-map']") == "map"
    end

    test "a status attr renders the shared status badge" do
      html =
        render_component(&AdminResource.value/1,
          shape: :enum,
          value: :pending,
          status?: true
        )

      assert text_of(html, "[data-testid='status-badge']") == "Submitted"
      refute html =~ "admin-resource-enum"
    end

    test "the same enum without the status flag stays the neutral enum badge" do
      html = render_component(&AdminResource.value/1, shape: :enum, value: :pending)

      assert text_of(html, "[data-testid='admin-resource-enum']") == "Pending"
      refute html =~ "status-badge"
    end

    test "a decimal renders its raw value, mono, with no currency inference" do
      value = Decimal.new("2.5")

      index =
        render_component(&AdminResource.value/1, shape: :decimal, value: value, variant: :index)

      show =
        render_component(&AdminResource.value/1, shape: :decimal, value: value, variant: :show)

      assert text_of(index, "span") == "2.5"
      assert text_of(show, "span") == "2.5"
      refute index =~ "$"
      refute show =~ "$"
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

      cell =
        render_component(&AdminResource.value/1,
          shape: :unknown,
          value: {:tuple, 1},
          variant: :index
        )

      assert text_of(cell, "span") == "{:tuple, 1}"
      assert cell =~ "truncate"
      assert cell =~ ~s(title="{:tuple, 1}")
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

  describe "the input mapping (the plan's form contracts table)" do
    test "string, ci_string, and uuid shape to text" do
      key = attr(FeatureFlag, :key)
      domain = attr(AccessRule, :domain)

      assert AdminResource.input_type(key) == "text"
      assert AdminResource.input_type(domain) == "text"
      assert AdminResource.input_type(%{type: Ash.Type.UUID}) == "text"
    end

    test "integer shapes to number, boolean to checkbox" do
      rollout = attr(FeatureFlag, :rollout_percentage)
      enabled = attr(FeatureFlag, :enabled)

      assert AdminResource.input_type(rollout) == "number"
      assert AdminResource.input_type(%{type: Ash.Type.Decimal}) == "number"
      assert AdminResource.input_type(enabled) == "checkbox"
    end

    test "a one_of atom shapes to select and builds its options from the constraint" do
      purpose = attr(AccessRule, :purpose)

      assert AdminResource.input_type(purpose) == "select"
      assert AdminResource.enum_options(purpose) == [{"Auth", "auth"}, {"Feedback", "feedback"}]
    end

    test "a custom enum type selects like a one_of, its options from values/0" do
      type = attr(FluxVale.Billing.LedgerEntry, :type)

      assert AdminResource.input_type(type) == "select"
      assert AdminResource.enum_options(type) == [{"Credit", "credit"}, {"Debit", "debit"}]
    end

    test "datetime attrs shape to the datetime-local input (TaxRate effective_from)" do
      effective = attr(FluxVale.Pricing.TaxRate, :effective_from)

      assert AdminResource.input_type(effective) == "datetime-local"
      assert AdminResource.input_type(%{type: Ash.Type.UtcDatetime}) == "datetime-local"
    end

    test "JSON-shaped composites map to the textarea; unmappable shapes stay nil" do
      # Slice 4's JSON-textarea contract: maps, arrays of scalars, and
      # the module composites all cast from JSON-shaped plain maps.
      assert AdminResource.input_type(%{type: Ash.Type.Map}) == "textarea"
      assert AdminResource.input_type(%{type: {:array, Ash.Type.String}}) == "textarea"

      # Ash.Type.Atom without one_of still answers nil — its specific
      # clause precedes the atom-composite clause.
      assert AdminResource.input_type(%{type: Ash.Type.Atom, constraints: []}) == nil

      # Array-of-array stays unmappable — the guard pins it against the
      # recursion re-entering the array-of-string clause.
      assert AdminResource.input_type(%{type: {:array, {:array, Ash.Type.String}}}) == nil

      # An array whose inner maps to a non-textarea input stays
      # unmappable too.
      assert AdminResource.input_type(%{type: {:array, Ash.Type.Integer}}) == nil

      # A fabricated non-atom non-array type is the _unmapped fallback.
      assert AdminResource.input_type(%{type: {:custom_tuple, :x}}) == nil
    end

    test "the Catalog composites textarea (the atom-composite and array clauses)" do
      env_vars = attr(FluxVale.Catalog.AppVersion, :default_env_vars)
      schema = attr(FluxVale.Catalog.AppVersion, :configurable_env_vars)
      services = attr(FluxVale.Catalog.AppVersion, :backing_services)
      features = attr(FluxVale.Catalog.App, :features)
      caveats = attr(FluxVale.Catalog.App, :caveats)

      assert AdminResource.input_type(env_vars) == "textarea"
      assert AdminResource.input_type(schema) == "textarea"
      assert AdminResource.input_type(services) == "textarea"
      assert AdminResource.input_type(features) == "textarea"
      assert AdminResource.input_type(caveats) == "textarea"

      # A one_of atom still selects. Any non-enum atom type reads as a
      # module composite — the probe-verified JSON-cast contract the
      # Catalog types ride; a built-in landing here would fail at cast
      # time as a field error, and the registry-intake tests surface
      # it at intake.
      purpose = attr(AccessRule, :purpose)
      assert AdminResource.input_type(purpose) == "select"
      assert AdminResource.input_type(%{type: SomeUnmappedCompositeType}) == "textarea"
      assert AdminResource.input_type(%{type: SomeNonArrayType}) == "textarea"
    end

    test "decimal inputs step by hundredths — the browser default of 1 would reject fractions" do
      cpu = attr(FluxVale.Pricing.Size, :cpu_cores)
      memory = attr(FluxVale.Pricing.Size, :memory_mb)

      assert AdminResource.input_step(cpu) == "0.01"
      assert AdminResource.input_step(memory) == nil
    end

    test "array-of-uuid arguments map to the JSON textarea (slice 6: set_tags)" do
      assert AdminResource.input_type(%{type: {:array, Ash.Type.UUID}}) == "textarea"
    end

    test "set_tags maps tag_ids to a required textarea; set_status status to a six-option select" do
      set_tags = Info.action(Post, :set_tags)
      set_tags_fields = Resources.form_fields(Post, set_tags)
      tag_ids = Enum.find(set_tags_fields, &(&1.name == :tag_ids))

      assert tag_ids.type == "textarea"
      assert tag_ids.required

      set_status = Info.action(Post, :set_status)
      set_status_fields = Resources.form_fields(Post, set_status)
      status = Enum.find(set_status_fields, &(&1.name == :status))

      assert status.type == "select"

      assert status.options == [
               {"Open", "open"},
               {"Planned", "planned"},
               {"Started", "started"},
               {"Completed", "completed"},
               {"Duplicate", "duplicate"},
               {"Declined", "declined"}
             ]
    end

    test "required-ness follows allow_nil?, except checkboxes" do
      key = attr(FeatureFlag, :key)
      rollout = attr(FeatureFlag, :rollout_percentage)
      enabled = attr(FeatureFlag, :enabled)

      assert AdminResource.input_required?(key, "text")
      assert not AdminResource.input_required?(rollout, "number")

      # enabled is allow_nil? false, but a checkbox always submits a
      # real value — required would force every boolean on.
      assert not AdminResource.input_required?(enabled, "checkbox")
    end
  end

  describe "the write affordances (visible?-gated)" do
    test "the create affordance renders the New link to the :new route" do
      html =
        render_component(&AdminResource.new_button/1,
          path: "/admin/resources/ops/feature_flag/new"
        )

      assert html =~ ~s(data-testid="admin-resource-new")
      assert html =~ ~s(href="/admin/resources/ops/feature_flag/new")
      assert text_of(html, "a") == "New"
    end

    test "no permitted create action renders nothing at all" do
      assert render_component(&AdminResource.new_button/1, path: nil) == ""
    end

    test "the actions bar carries one Edit link and one Delete button per permitted action" do
      html =
        render_component(&AdminResource.actions_bar/1,
          update_actions: [
            %{name: :update, path: "/x/edit?action=update", label: "Edit"}
          ],
          destroy_actions: [%{name: :destroy, label: "Delete"}]
        )

      edit = text_of(html, "a[data-testid='admin-resource-edit-update']")
      assert edit == "Edit"

      delete_nodes =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-testid='admin-resource-destroy-destroy']")
        |> Enum.to_list()

      assert delete_nodes != []
      assert html =~ ~s(phx-click="open-destroy")
      assert html =~ ~s(phx-value-action="destroy")
      assert html =~ ~s(phx-disable-with)
    end

    test "no permitted action renders no bar — not an empty box" do
      assert render_component(&AdminResource.actions_bar/1,
               update_actions: [],
               destroy_actions: []
             ) == ""
    end
  end

  describe "the FK link cell (slice 4)" do
    test "link_value renders the label linked to its path" do
      path = "/admin/resources/catalog/app/01a1b89f-0c37-7660-8970-2b93c7181a59"

      html =
        render_component(&AdminResource.link_value/1,
          label: "Probe App",
          path: path,
          record_id: "02b2c90f-1d48-8771-9081-3c04d8292b70"
        )

      link =
        text_of(html, "a[data-testid='admin-resource-fk-02b2c90f-1d48-8771-9081-3c04d8292b70']")

      assert link == "Probe App"
      assert html =~ ~s(href="#{path}")
    end
  end
end
