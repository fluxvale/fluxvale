defmodule FluxValeWeb.AdminHealthLiveTest do
  @moduledoc false

  # The Health section (#702): the fleet at a glance through the real
  # mount. The route gates here are the shared live_session's arms
  # (the anonymous 302 and the non-admin 403, pinned once — the
  # people/audit tests' shape). Sync module: tests manipulate the app
  # env (the capture-and-restore posture; ExUnit runs sync modules
  # alone).

  use FluxValeWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  setup :verify_on_exit!
  # The runway-unknown test stubs the projection operation and needs
  # the stub visible from the LiveView process, not just the test
  # process — global mode (safe here: the module is sync, ExUnit runs
  # it alone).
  setup :set_mimic_global

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Operations.ComputeRunway
  alias FluxVale.Billing.Wallet
  alias FluxVale.Feedback.Tag
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Observability.WakeStats
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.SessionHelpers
  alias FluxVale.TestSupport.StorageRequestFixtures
  alias FluxValeWeb.AdminHealth

  @n :erlang.unique_integer([:positive])

  setup %{conn: conn} do
    InstanceFixtures.local_cluster!()

    admin =
      User.create!("admin-health-live-#{@n}@fluxvale.com", %{platform_role: :admin},
        authorize?: false
      )

    %{admin: admin, conn: SessionHelpers.sign_in(conn, admin), bare_conn: conn}
  end

  # A fleet fixture through actions (the fixture user's funded
  # personal org owns it; the admin reads it through the blanket
  # bypass), always-on toggled on so the summary numbers carry a
  # delta, plus fabricated version rows — Ash.Seed is the sanctioned
  # bypass: the real :deploy action enqueues k8s/Oban work a test must
  # not run. The trail gets a deploy row with an actor and one with
  # the nil tombstone (both render arms); a :create row rides its own
  # source id, dated NEWEST — if the trail's filter ever broke, the
  # creator's row would lead it. The before-read is the delta baseline
  # for the summary-number assertions (the seam itself, same admin
  # actor the mount will use).
  defp fleet_fixtures!(admin) do
    version = InstanceFixtures.app_version!(configurable_env_vars: %{})
    member = AccountsFixtures.user!()

    before = AdminHealth.fleet(admin)

    instance = InstanceFixtures.instance!(version, member)
    Instance.set_always_on!(instance, %{always_on: true}, actor: member)

    source = Ecto.UUID.generate()
    create_source = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
      version_action_type: :update,
      version_action_name: :deploy,
      version_action_inputs: %{},
      version_source_id: source,
      actor_label: "deployer",
      version_inserted_at: now,
      changes: %{}
    })

    Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
      version_action_type: :update,
      version_action_name: :deploy,
      version_action_inputs: %{},
      version_source_id: source,
      actor_label: nil,
      version_inserted_at: DateTime.add(now, -60, :second),
      changes: %{}
    })

    Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
      version_action_type: :create,
      version_action_name: :create,
      version_action_inputs: %{},
      version_source_id: create_source,
      actor_label: "creator",
      version_inserted_at: DateTime.add(now, 600, :second),
      changes: %{}
    })

    %{source: source, create_source: create_source, before: before}
  end

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  # The wake maps come from WakeStats — the app tree's named server
  # fed by PromEx, which this suite never starts. The stub rides the
  # wake_stats test's own tooling: raise the TTL so an injected cache
  # is served, then inject both maps through :sys.replace_state (OTP
  # tooling, not an app backdoor). On exit BOTH pieces of app-owned
  # state go back — the TTL (capture-and-restore) and the cache itself
  # — so no fabricated map can outlive the test even for a later
  # TTL-raising reader.
  defp wake_stub!(p95_promotion, median_total) do
    original_ttl = Application.get_env(:flux_vale, :wake_stats_ttl_seconds)
    Application.put_env(:flux_vale, :wake_stats_ttl_seconds, 3600)

    on_exit(fn ->
      if original_ttl == nil do
        Application.delete_env(:flux_vale, :wake_stats_ttl_seconds)
      else
        Application.put_env(:flux_vale, :wake_stats_ttl_seconds, original_ttl)
      end
    end)

    previous_state = :sys.get_state(WakeStats)

    on_exit(fn ->
      :sys.replace_state(WakeStats, fn _state -> previous_state end)
    end)

    computed_at = DateTime.utc_now()

    :sys.replace_state(WakeStats, fn _state ->
      %{computed_at: computed_at, medians: median_total, p95_promotions: p95_promotion}
    end)
  end

  # The burning wallet of the seam tests' shape: a grant-free org's
  # wallet funded to exactly 1¢ through the posting action, its owner's
  # instance walked to :running on the fixture version — 140¢/mo of
  # burn (the compute class plus the 10 GB storage axis) against the
  # funded balance, ≈ 5.2 hours of runway per cent under the default
  # one-week gate. `name` renames the org (every grant-free org shares
  # one fixture name, and the widget renders the name); `balance`
  # scales the runway figure.
  defp burning_wallet!(opts \\ []) do
    version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)
    {fixture_org, owner} = BillingFixtures.grant_free_org!()
    org = renamed_org(fixture_org, Keyword.get(opts, :name))

    {:ok, wallet} = Billing.ensure_wallet(org)

    {:ok, _grant} =
      Billing.grant_credits(wallet, Keyword.get(opts, :balance, 1), reason: :adjustment)

    instance =
      Instance.create!(
        %{
          name: "Burner #{System.unique_integer([:positive])}",
          app_version_id: version.id,
          env_vars: %{}
        },
        actor: owner
      )

    running = InstanceFixtures.walk_to!(instance, :running)
    InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{instance.id}")

    {org, wallet}
  end

  # authorize?: false — the fixture posture (system bootstrap,
  # mirroring the seeds; the rename itself is the owner's action).
  defp renamed_org(org, nil), do: org

  defp renamed_org(org, name) do
    Organization.update!(org, %{name: name}, authorize?: false)
  end

  defp flag!(actor, suffix) do
    FeatureFlag
    |> Ash.Changeset.for_create(:create, %{key: "c4_flag_#{suffix}_#{@n}"}, actor: actor)
    |> Ash.create!()
  end

  defp tag!(actor, name) do
    Tag
    |> Ash.Changeset.for_create(:create, %{name: name}, actor: actor)
    |> Ash.create!()
  end

  # The low list's rows, one text per li — the order the panel rendered.
  defp low_rows(view) do
    html = render(view)
    document = LazyHTML.from_fragment(html)

    document
    |> LazyHTML.query("[data-testid='runway-low'] li")
    |> Enum.to_list()
    |> Enum.map(fn li ->
      text = LazyHTML.text(li)
      String.trim(text)
    end)
  end

  describe "the fleet surface" do
    test "an admin sees the section, the spread, and the deploy trail", %{
      conn: conn,
      admin: admin
    } do
      %{source: source, create_source: create_source, before: before} = fleet_fixtures!(admin)

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='admin-health']")
      assert has_element?(view, "[data-testid='admin-health-title']", "Health")

      # The build stamp: the version chip always renders (its value is
      # pinned against a stubbed sha in the dedicated test below); the
      # env chip rides config's "local" default.
      assert has_element?(view, "[data-testid='fleet-version']")
      assert has_element?(view, "[data-testid='fleet-env']")

      # The summary numbers, exact for the fixture state: the deltas
      # this test created (+1 instance, +1 always-on) over the
      # before-read — the partition's committed strays are IN the
      # before-read, so the absolute number is this test's own.
      assert text_of(view, "[data-testid='fleet-total']") ==
               ngettext_exact(before.total + 1, "1 instance", "%{count} instances")

      assert text_of(view, "[data-testid='fleet-always-on']") ==
               ngettext_exact(before.always_on + 1, "1 always-on", "%{count} always-on")

      # The spread renders the product's own vocabulary (#179) through
      # the shared status_badge: the created instance lands :pending —
      # "Submitted".
      assert has_element?(view, "[data-testid='fleet-status-pending']", "Submitted")

      # The trail rows: the engine's short id, the recorded actor
      # label, and the nil tombstone's honest System attribution. The
      # creator's row (the table's newest, on its own source) renders
      # nowhere — the deploy-only filter holds through the mount.
      deploys_text = text_of(view, "[data-testid='fleet-deploys']")
      assert deploys_text =~ String.slice(source, 0, 8)
      assert deploys_text =~ "deployer"
      assert deploys_text =~ "System"
      refute deploys_text =~ "creator"
      refute deploys_text =~ String.slice(create_source, 0, 8)

      # The empty line stays quiet while the trail has rows.
      refute has_element?(view, "[data-testid='fleet-deploys-empty']")

      # The section's sidebar entry is the page; siblings stay quiet.
      assert has_element?(view, "[data-testid='admin-nav-health'][aria-current='page']")
      refute render(element(view, "[data-testid='admin-nav-audit']")) =~ "aria-current"
    end

    test "the version chip renders the pinned build sha", %{conn: conn} do
      # The stub_build_sha posture (the health controller tests'
      # shape): assertions own their preconditions — ambient BUILD_SHA
      # from the environment included — so the chip's rendered value
      # is this test's own, not the runner's mood.
      previous = Application.get_env(:flux_vale, :build_sha)
      Application.put_env(:flux_vale, :build_sha, "c1fixsha")

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:flux_vale, :build_sha)
        else
          Application.put_env(:flux_vale, :build_sha, previous)
        end
      end)

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='fleet-version']", "Version: sha-c1fixsha")
    end

    test "the env chip renders nothing when the platform has no env", %{conn: conn} do
      # Capture-and-restore (the stub_build_sha posture): config.exs
      # defaults "local", so the nil shape arrives only when unset.
      original = Application.get_env(:flux_vale, :platform_env)
      Application.put_env(:flux_vale, :platform_env, nil)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:flux_vale, :platform_env)
        else
          Application.put_env(:flux_vale, :platform_env, original)
        end
      end)

      {:ok, view, _html} = live(conn, "/admin/health")

      refute has_element?(view, "[data-testid='fleet-env']")
      assert has_element?(view, "[data-testid='fleet-version']")

      # The emptiness claim is scoped to what this test controls: a
      # source id it fabricated and never seeded can never name a
      # trail row. The partition's committed rows are not this test's
      # to assert absent — a has-element claim on the empty line would
      # own a global state that is not ours.
      fabricated = Ecto.UUID.generate()

      refute text_of(view, "[data-testid='fleet-deploys']") =~ String.slice(fabricated, 0, 8)
    end
  end

  # The ngettext branches, spelled out — a fresh partition with zero
  # strays renders the singular, and the always-on plural never takes
  # an s.
  defp ngettext_exact(1, singular, _plural), do: singular

  defp ngettext_exact(count, _singular, plural),
    do: String.replace(plural, "%{count}", Integer.to_string(count))

  describe "the wake surface" do
    test "the wake rows render per app with both families' seconds", %{conn: conn} do
      # kavita rides both families; forgejo is known only by its p95
      # (median renders the honest dash); gerbera only by its median
      # (the p95 dash). The injected cache is the row set's only
      # source — an app in neither family can never render, so the
      # absence below is this test's own.
      wake_stub!(
        %{"kavita" => 2.95, "forgejo" => 4.1},
        %{"kavita" => 6.5, "gerbera" => 90.5}
      )

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='wake-panel']")
      assert has_element?(view, "[data-testid='wake-title']", "Wakes")

      # The numbers, exact for the stubbed estimates through the
      # catalog badge's one formatter (~-rounded seconds, minutes over
      # a minute).
      kavita = text_of(view, "[data-testid='wake-kavita']")
      assert kavita =~ "p95 promotion ~3s"
      assert kavita =~ "median total ~7s"

      forgejo = text_of(view, "[data-testid='wake-forgejo']")
      assert forgejo =~ "p95 promotion ~4s"
      assert forgejo =~ "median total -"

      gerbera = text_of(view, "[data-testid='wake-gerbera']")
      assert gerbera =~ "p95 promotion -"
      assert gerbera =~ "median total ~1m 31s"

      # Rows present means the empty line stays quiet.
      refute has_element?(view, "[data-testid='wake-empty']")

      refute has_element?(view, "[data-testid='wake-promnesia']")
    end

    test "the wake panel renders the honest empty line when no app has numbers", %{conn: conn} do
      # PromEx off is the default local state — the injected empty pair
      # is the row set's only source, so the no-rows claim is this
      # test's own.
      wake_stub!(%{}, %{})

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='wake-panel']")
      assert text_of(view, "[data-testid='wake-empty']") =~ "No wake data yet"
      assert text_of(view, "[data-testid='wake-caveat']") =~ "reset on every deploy"

      refute has_element?(view, "[data-testid='wake-kavita']")
    end
  end

  describe "the storage surface" do
    test "the chips render the seam's numbers and the queue deep-link", %{
      conn: conn,
      admin: admin
    } do
      # One instance (+20 GB) and one request (+1 requested) of this
      # test's own, then the post-fixture seam read is what the chips
      # must render — the exact ngettext strings, not element presence.
      version = InstanceFixtures.app_version!(default_storage_gb: 10, monthly_cents: 100)
      member = AccountsFixtures.user!()

      instance =
        Instance.create!(
          %{
            name: "Chips #{System.unique_integer([:positive])}",
            app_version_id: version.id,
            env_vars: %{},
            storage_gb: 20
          },
          actor: member
        )

      StorageRequestFixtures.request!(instance, member, %{requested_gb: 150})

      expected = AdminHealth.storage(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='storage-panel']")
      assert has_element?(view, "[data-testid='storage-title']", "Storage")

      assert text_of(view, "[data-testid='storage-allocated']") ==
               ngettext_exact(expected.allocated_gb, "1 GB allocated", "%{count} GB allocated")

      assert text_of(view, "[data-testid='storage-requested']") ==
               ngettext_exact(expected.requested, "1 requested", "%{count} requested")

      assert text_of(view, "[data-testid='storage-approved']") ==
               ngettext_exact(expected.approved, "1 approved", "%{count} approved")

      assert text_of(view, "[data-testid='storage-applied']") ==
               ngettext_exact(expected.applied, "1 applied", "%{count} applied")

      # The runbook note is text, not a link — the runbook is not served.
      assert text_of(view, "[data-testid='storage-runbook']") =~ "block-storage runbook"

      assert render(element(view, "[data-testid='storage-link']")) =~
               "href=\"/admin/storage-requests\""
    end
  end

  describe "the runway surface" do
    test "the healthy page renders the above-the-gate line", %{conn: conn} do
      # No fixture: the partition's wallets (the admin's own included)
      # project :infinity — no lows, no unknowns, no escapees, no
      # failures, so the healthy line is the panel's only story.
      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='runway-empty']", "Every wallet is above the gate.")
      refute has_element?(view, "[data-testid='runway-low']")
      refute has_element?(view, "[data-testid='runway-more']")
      refute has_element?(view, "[data-testid='runway-depleted']")
      refute has_element?(view, "[data-testid='runway-unknown']")
      refute has_element?(view, "[data-testid='runway-unavailable']")
    end

    test "the gate line, the low row, and the deep link render", %{conn: conn, admin: admin} do
      # The burning wallet of the seam tests' shape: 1¢ against the
      # fixture's 140¢/mo burn — the one low row this test owns,
      # named so the row's identity is this test's own.
      {org, _wallet} = burning_wallet!(name: "Gate Runner")

      expected = AdminHealth.runway(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='runway-panel']")
      assert has_element?(view, "[data-testid='runway-title']", "Org runway")
      assert text_of(view, "[data-testid='runway-gate']") == "Wallets under 168h of runway"

      # The low row: the org's name and slug (names are not unique —
      # the slug rides beside it in mono), and the formatted hours
      # through the billing display seam's projection formatter
      # (10_000 µ¢ ÷ 1916 µ¢/h rounds to "≈ 5 hours").
      low = text_of(view, "[data-testid='runway-low']")
      assert low =~ org.name
      assert low =~ org.slug
      assert low =~ "≈ 5 hours"
      assert expected.threshold_hours == 168

      assert render(element(view, "[data-testid='runway-link']")) =~ "href=\"/admin/billing\""

      refute has_element?(view, "[data-testid='runway-empty']")
      refute has_element?(view, "[data-testid='runway-more']")
      refute has_element?(view, "[data-testid='runway-depleted']")

      # No stubbed errors here — the unknown count stays quiet.
      refute has_element?(view, "[data-testid='runway-unknown']")
    end

    test "unknown projections render the honest count and never a row", %{
      conn: conn,
      admin: admin
    } do
      # Every projection errors — the unknown count is every wallet,
      # the low list renders nothing, and the unknown count carries
      # the story (the above-the-gate line stays quiet).
      Mimic.copy(ComputeRunway)
      stub(ComputeRunway, :call, fn _wallet -> {:error, :projection_dead} end)

      expected = AdminHealth.runway(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert expected.unknown == expected.wallets
      assert expected.unknown >= 1

      assert text_of(view, "[data-testid='runway-unknown']") ==
               ngettext_exact(
                 expected.unknown,
                 "1 projection unknown",
                 "%{count} projections unknown"
               )

      refute has_element?(view, "[data-testid='runway-low']")
      refute has_element?(view, "[data-testid='runway-empty']")
    end

    test "a mixed page renders the list and the unknown count together", %{
      conn: conn,
      admin: admin
    } do
      {org, _wallet} = burning_wallet!()
      target_org_id = org.id

      # The stub answers only this test's wallet with a hand-built low
      # projection and errors every other wallet — the mixed page: one
      # known low row beside the unknown count, the empty line quiet.
      Mimic.copy(ComputeRunway)

      stub(ComputeRunway, :call, fn wallet ->
        if wallet.organization_id == target_org_id do
          {:ok, %{balance_cents: 1, runway_hours: 5.2}}
        else
          {:error, :projection_dead}
        end
      end)

      expected = AdminHealth.runway(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert expected.unknown == expected.wallets - 1
      assert length(expected.low) == 1

      low = text_of(view, "[data-testid='runway-low']")
      assert low =~ org.name
      assert low =~ "≈ 5 hours"

      assert text_of(view, "[data-testid='runway-unknown']") ==
               ngettext_exact(
                 expected.unknown,
                 "1 projection unknown",
                 "%{count} projections unknown"
               )

      refute has_element?(view, "[data-testid='runway-empty']")
    end

    test "the low list caps at ten with an honest overflow count", %{conn: conn, admin: admin} do
      # Bulk volume — the sanctioned Ash.Seed escape: 12 orgs with
      # wallets. The global stub answers every projection with a low
      # figure, so every wallet lands low and the render must cap at
      # ten rows with the honest "and N more".
      for i <- 1..12 do
        Ash.Seed.seed!(Organization, %{
          name: "overflow-org-#{i}",
          slug: "overflow-org-#{i}",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

        Ash.Seed.seed!(Wallet, %{
          organization_id: Organization.get_by_slug!("overflow-org-#{i}", authorize?: false).id,
          carryover: 0,
          paywall_waived: false,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })
      end

      Mimic.copy(ComputeRunway)

      stub(ComputeRunway, :call, fn _wallet ->
        {:ok, %{balance_cents: 1, runway_hours: 5.2}}
      end)

      expected = AdminHealth.runway(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert length(low_rows(view)) == 10

      assert text_of(view, "[data-testid='runway-more']") ==
               ngettext_exact(
                 length(expected.low) - 10,
                 "and 1 more",
                 "and %{count} more"
               )

      refute has_element?(view, "[data-testid='runway-empty']")
    end

    test "a spent wallet with nothing burning renders the depleted count", %{
      conn: conn,
      admin: admin
    } do
      # The escapee shape: funded, debited past zero, no instances —
      # balance < 0 with :infinity runway. The panel must say it: the
      # depleted count line renders and the healthy line stays quiet.
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(wallet, 10_000, reason: :adjustment)
      {:ok, _debit} = Billing.debit_wallet(wallet, 200_000_000)

      expected = AdminHealth.runway(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert expected.depleted >= 1

      assert text_of(view, "[data-testid='runway-depleted']") ==
               ngettext_exact(
                 expected.depleted,
                 "1 depleted wallet",
                 "%{count} depleted wallets"
               )

      refute has_element?(view, "[data-testid='runway-low']")
      refute has_element?(view, "[data-testid='runway-empty']")
    end

    test "a failed widget read renders the honest unavailable line", %{conn: conn, admin: admin} do
      # The org lookup is the runway widget's failure boundary: raise
      # it and the widget degrades to its unavailable line — the read
      # failure the 250-org dev DB proved reachable — never a 500.
      Mimic.copy(Ash)

      stub(Ash, :run_action!, fn _input ->
        raise "lookup down"
      end)

      expected = AdminHealth.runway(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert expected.unavailable == true
      assert has_element?(view, "[data-testid='runway-unavailable']", "Runway data unavailable.")
      refute has_element?(view, "[data-testid='runway-low']")
      refute has_element?(view, "[data-testid='runway-empty']")
    end

    test "a spent wallet reads Depleted in the low row", %{conn: conn, admin: admin} do
      # The burning wallet overdrawn below zero: the projection's hours
      # go negative and the shared formatter names the state — the low
      # row is this wallet's row, so the depleted COUNT (escapees with
      # no burn) stays quiet.
      {org, wallet} = burning_wallet!()
      {:ok, _overdraw} = Billing.debit_wallet(wallet, 200 * 10_000)

      _expected = AdminHealth.runway(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      low = text_of(view, "[data-testid='runway-low']")
      assert low =~ org.name
      assert low =~ "Depleted"

      refute has_element?(view, "[data-testid='runway-depleted']")
      refute has_element?(view, "[data-testid='runway-empty']")
    end
  end

  describe "the audit activity surface" do
    test "renders the total, the top rows, and the deep link", %{conn: conn, admin: admin} do
      # The fourth-place count bounds the fixture arithmetic: `fourth + 1`
      # outranks every pre-existing row but the top three, so committed
      # partition strays can never crowd the feature-flag row out of the
      # top five. A clean partition's fourth is zero.
      before = AdminHealth.audit_activity(admin)

      fourth =
        before.top
        |> Enum.at(3)
        |> then(&(&1 && &1.count)) || 0

      for i <- 1..(fourth + 1), do: flag!(admin, "live_#{i}")
      for i <- 1..(fourth + 2), do: tag!(admin, "c4-live-tag-#{i}-#{@n}")

      expected = AdminHealth.audit_activity(admin)
      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(view, "[data-testid='audit-activity']")

      assert text_of(view, "[data-testid='audit-activity-total']") ==
               ngettext_exact(
                 expected.total,
                 "1 change in the last 24 hours",
                 "%{count} changes in the last 24 hours"
               )

      row = Enum.find(expected.top, &(&1.key == :feature_flag))
      assert row

      row_text = text_of(view, "[data-testid='audit-activity-feature_flag']")
      assert row_text =~ ngettext_exact(row.count, "1 change", "%{count} changes")
      assert row_text =~ "Feature flag"

      assert render(element(view, "[data-testid='audit-link']")) =~ "href=\"/admin/audit\""
      refute has_element?(view, "[data-testid='audit-activity-empty']")
    end

    test "the honest empty line when there is no activity", %{conn: conn} do
      Mimic.copy(FluxValeWeb.AdminHealth)

      stub(AdminHealth, :audit_activity, fn _actor -> %{total: 0, active: 0, top: []} end)

      {:ok, view, _html} = live(conn, "/admin/health")

      assert has_element?(
               view,
               "[data-testid='audit-activity-empty']",
               "No audit activity in the last 24 hours."
             )

      refute has_element?(view, "[data-testid='audit-activity-top']")
    end

    test "renders the honest overflow count past the top five", %{conn: conn} do
      # Hermetic render arm: the seam reports seven active resources and
      # five capped rows, so the panel must say two are not shown.
      Mimic.copy(FluxValeWeb.AdminHealth)

      top = [
        %{key: :wallet, label: "Wallet", count: 4},
        %{key: :ledger_entry, label: "Ledger entry", count: 3},
        %{key: :app, label: "App", count: 2},
        %{key: :user, label: "User", count: 2},
        %{key: :tag, label: "Tag", count: 1}
      ]

      stub(AdminHealth, :audit_activity, fn _actor ->
        %{total: 16, active: 7, top: top}
      end)

      {:ok, view, _html} = live(conn, "/admin/health")

      assert text_of(view, "[data-testid='audit-activity-total']") ==
               ngettext_exact(
                 16,
                 "1 change in the last 24 hours",
                 "%{count} changes in the last 24 hours"
               )

      assert text_of(view, "[data-testid='audit-activity-more']") == "and 2 more resources"
      assert has_element?(view, "[data-testid='audit-activity-wallet']")
      refute has_element?(view, "[data-testid='audit-activity-empty']")
    end
  end

  describe "the gates" do
    test "anonymous bounces to /sign-in", %{bare_conn: conn} do
      conn = get(conn, "/admin/health")

      assert conn.status == 302
      assert ["/sign-in"] = get_resp_header(conn, "location")
    end

    test "a signed-in non-admin gets a bare 403", %{bare_conn: conn} do
      user = SessionHelpers.user!()
      signed = SessionHelpers.sign_in(conn, user)
      conn = get(signed, "/admin/health")

      assert conn.status == 403
    end
  end
end
