defmodule FluxValeWeb.AdminHealthTest do
  @moduledoc false

  # The Health section's widget seam (#702): fleet/1 through the real
  # reads. The partition DB carries committed instance strays from
  # other lanes, so every count asserts a DELTA around this test's own
  # writes — the exact discipline the audit section's tests ride (#241).
  # The module is sync because tests manipulate the app env (the
  # capture-and-restore posture); ExUnit runs sync modules alone.

  use FluxVale.DataCase, async: false
  use Mimic

  setup :verify_on_exit!

  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.Month
  alias FluxVale.Billing.Wallet
  alias FluxVale.Catalog.Category
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Feedback.Tag
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Cluster
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.Ops.FeatureFlag
  alias FluxVale.Pricing.Size
  alias FluxVale.Pricing.TaxRate
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.StorageRequestFixtures
  alias FluxValeWeb.AdminAudit
  alias FluxValeWeb.AdminHealth

  @n :erlang.unique_integer([:positive])

  # The fixture's pinned monthly rate (the compute class plus the
  # 10 GB storage axis) — the expected hours arithmetic rides
  # hourly_micro/1 below, over Billing.Month's own constant.
  @fixture_monthly_cents 140

  # Bootstrap posture: precondition admins pass authorize?: false
  # (mirrors the audit section's tests' setup). The local cluster row
  # rides first — ResolveCluster pins it on every instance create.
  setup do
    InstanceFixtures.local_cluster!()

    admin =
      User.create!("admin-health-#{@n}@fluxvale.com", %{platform_role: :admin}, authorize?: false)

    %{admin: admin}
  end

  describe "fleet/1" do
    test "counts action-created instances in statuses, totals, and the always-on set", %{
      admin: admin
    } do
      version = InstanceFixtures.app_version!(configurable_env_vars: %{})
      member = AccountsFixtures.user!()

      before = AdminHealth.fleet(admin)

      # One instance stays :pending (the create's landing state), one
      # walks the funnel's legal chain to :running — both through
      # actions, never seeds.
      InstanceFixtures.instance!(version, member)

      started = InstanceFixtures.instance!(version, member)
      running = InstanceFixtures.walk_to!(started, :running)

      Instance.set_always_on!(running, %{always_on: true}, actor: member)

      fleet = AdminHealth.fleet(admin)

      assert fleet.total == before.total + 2
      assert fleet.statuses[:pending] == (before.statuses[:pending] || 0) + 1
      assert fleet.statuses[:running] == (before.statuses[:running] || 0) + 1
      assert fleet.always_on == before.always_on + 1
    end

    test "recent_deploys returns only deploy rows, newest first, five at most", %{admin: admin} do
      source = Ecto.UUID.generate()
      base = DateTime.utc_now()

      for i <- 1..6 do
        # Ash.Seed is the sanctioned bypass: the real :deploy action
        # enqueues k8s/Oban work a unit test must not run, so the
        # version rows are fabricated directly. Future-dated stamps
        # keep this test hermetic against the partition's committed
        # strays (they can only ever be older than these).
        Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
          version_action_type: :update,
          version_action_name: :deploy,
          version_action_inputs: %{},
          version_source_id: source,
          actor_label: "deployer-#{i}",
          version_inserted_at: DateTime.add(base, i * 60, :second),
          changes: %{}
        })
      end

      # The shape the real create writes — never a deploy row, must
      # stay out of the trail. Dated NEWEST (past every deploy row) so
      # the five-row cap cannot mask it: if the filter ever broke, the
      # creator's row would lead the trail.
      Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
        version_action_type: :create,
        version_action_name: :create,
        version_action_inputs: %{},
        version_source_id: source,
        actor_label: "creator",
        version_inserted_at: DateTime.add(base, 600, :second),
        changes: %{}
      })

      deploys = AdminHealth.fleet(admin).recent_deploys

      # The cap: seven candidates (six deploys + the create), five back.
      assert length(deploys) == 5

      # The filter: the newest row in the table is the create, and the
      # trail still names only deployers.
      actors = Enum.map(deploys, & &1.actor)
      refute "creator" in actors
      assert actors == ["deployer-6", "deployer-5", "deployer-4", "deployer-3", "deployer-2"]

      # Newest first on the version's own stamp.
      stamps = Enum.map(deploys, & &1.at)
      assert stamps == Enum.sort(stamps, {:desc, DateTime})

      # The mapping: the engine's short id.
      assert hd(deploys).source == String.slice(source, 0, 8)

      # A nil tombstone maps through untouched (the widget renders the
      # System attribution, not this seam) — and leads the trail once
      # seeded, while the create row (still the table's newest) stays
      # out.
      nil_row =
        Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
          version_action_type: :update,
          version_action_name: :deploy,
          version_action_inputs: %{},
          version_source_id: source,
          actor_label: nil,
          version_inserted_at: DateTime.add(base, 420, :second),
          changes: %{}
        })

      assert [latest | _rest] = AdminHealth.fleet(admin).recent_deploys
      assert latest.actor == nil_row.actor_label
      assert latest.at == nil_row.version_inserted_at
    end

    test "the seam is admin-only — a member actor and a nil actor are Forbidden" do
      # The pin the audit section carries: the version trail's read is
      # the mixin's direct admin-only policy (ADR-0048 D7). The
      # instance read alone would ADMIT a member (its policy is
      # org-scoped) — the refusal must come from the trail's read.
      member = AccountsFixtures.user!()

      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.fleet(member) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.fleet(nil) end
    end

    test "the registry keeps the :instance entry — the trail's resolution invariant" do
      entry = Enum.find(AdminAudit.entries(), &(&1.key == :instance))

      assert entry.module == Instance
      assert AdminAudit.version_module(entry) == Instance.Version
    end

    test "the build stamp passes env through", %{admin: admin} do
      # The env passthrough's nil arm: config.exs defaults "local", so
      # the nil shape only arrives when the env is unset — set it here,
      # restore on exit (the stub_build_sha posture).
      original = Application.get_env(:flux_vale, :platform_env)
      Application.put_env(:flux_vale, :platform_env, nil)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:flux_vale, :platform_env)
        else
          Application.put_env(:flux_vale, :platform_env, original)
        end
      end)

      assert AdminHealth.fleet(admin).env == nil

      Application.put_env(:flux_vale, :platform_env, "staging")
      assert AdminHealth.fleet(admin).env == "staging"
    end
  end

  describe "storage/1" do
    test "sums the fleet's allocation and drives the three queue counters", %{admin: admin} do
      # The capability probe is the one external touch inside approve —
      # stubbed like every storage-request suite (the live queue's shape).
      stub(K8s, :kubeconfig, fn nil -> {:ok, %{}} end)

      stub(StorageClass, :default_allows_expansion?, fn _kc -> {:ok, true} end)

      version = InstanceFixtures.app_version!(default_storage_gb: 10, monthly_cents: 100)
      member = AccountsFixtures.user!()

      # The approve's #124 wallet gate: the requests' org (the member's
      # personal org) funded through the posting action.
      org = AccountsFixtures.personal_org!(member)
      BillingFixtures.funded_wallet!(org: org)

      before = AdminHealth.storage(admin)

      # Three requests, each on its own instance (the one-open-per-
      # instance invariant): one stays :requested, one lands :approved
      # (the durable decision), one lands :applied. The first instance
      # carries an explicit 77 GB allocation so the allocated sum's
      # delta is this test's own.
      allocated =
        Instance.create!(
          %{
            name: "Allocated #{@n}",
            app_version_id: version.id,
            env_vars: %{},
            storage_gb: 77
          },
          actor: member
        )

      StorageRequestFixtures.request!(allocated, member, %{requested_gb: 150})

      approved_instance = running_deployed!(version, member)
      approved_request = StorageRequestFixtures.request!(approved_instance, member)

      {:ok, _approved} = StorageRequest.approve(approved_request, %{}, actor: admin)

      applied_instance = running_deployed!(version, member)
      applied_request = StorageRequestFixtures.request!(applied_instance, member)

      {:ok, approved} = StorageRequest.approve(applied_request, %{}, actor: admin)

      # The apply's success mark is a system action (no policy arm —
      # the operation runs it authorize?: false); the full apply runs
      # live k8s PVC growth a unit test must not run, so the state
      # rides the mark the way the fabricated deploy rows ride Ash.Seed.
      {:ok, _applied} = StorageRequest.mark_applied(approved, %{}, authorize?: false)

      storage = AdminHealth.storage(admin)

      # 97 = the explicit 77 GB allocation plus the two running
      # fixtures' 10 GB versions.
      assert storage.allocated_gb == before.allocated_gb + 97
      assert storage.requested == before.requested + 1
      assert storage.approved == before.approved + 1
      assert storage.applied == before.applied + 1
    end

    test "a legacy instance without an allocation counts as allocated nothing", %{admin: admin} do
      version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)
      member = AccountsFixtures.user!()

      before = AdminHealth.storage(admin)

      allocated =
        Instance.create!(
          %{
            name: "Allocated #{System.unique_integer([:positive])}",
            app_version_id: version.id,
            env_vars: %{},
            storage_gb: 30
          },
          actor: member
        )

      # Ash.Seed — the sanctioned escape: the create validation demands
      # an allocation, so the legacy row the `|| 0` arm defends against
      # can only exist as a hand-shaped row.
      Ash.Seed.seed!(Instance, %{
        name: "Legacy nil allocation",
        slug: "legacy-nil-#{System.unique_integer([:positive])}",
        app_version_id: version.id,
        organization_id: allocated.organization_id,
        cluster_id: allocated.cluster_id,
        env_vars: %{},
        status: :pending,
        storage_gb: nil
      })

      storage = AdminHealth.storage(admin)

      assert storage.allocated_gb == before.allocated_gb + 30
    end

    # The admin-only pins, per seam: storage refuses a member at the
    # queue read (the instance read admits them org-scoped) and nil at
    # the instance read; runway refuses a member at the org-name
    # lookup (#501 is admin-only — the member's own wallet read admits
    # them org-scoped) and nil at the wallet read. Either way the seam
    # raises the Forbidden.
    test "the seam is admin-only — a member actor and a nil actor are Forbidden" do
      member = AccountsFixtures.user!()

      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.storage(member) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.storage(nil) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.runway(member) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.runway(nil) end
    end
  end

  describe "runway/1" do
    test "low sorts most-urgent first and names each org its own name and slug", %{admin: admin} do
      before = AdminHealth.runway(admin)

      # Two named orgs, created in the WRONG order for urgency: the
      # 26-hour wallet first, the 5-hour one second. Organization.name
      # is not unique, so each row must carry its own name AND slug.
      {birch_org, _birch_wallet} = burning_wallet!(balance: 5, name: "Birch Labs")
      {alder_org, _alder_wallet} = burning_wallet!(balance: 1, name: "Alder Systems")

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets + 2
      assert runway.unknown == before.unknown
      assert runway.depleted == before.depleted

      new_rows = runway.low -- before.low

      assert [
               %{org: alder, slug: alder_slug, projection: alder_p},
               %{org: birch, slug: birch_slug, projection: birch_p}
             ] =
               new_rows

      assert alder == "Alder Systems"
      assert birch == "Birch Labs"
      assert alder_slug == alder_org.slug
      assert birch_slug == birch_org.slug
      assert alder_p.runway_hours < birch_p.runway_hours

      # The projection's own figure: the balance in µ¢ over the
      # fixture's 140¢/mo burn, divided over Billing.Month's seconds.
      assert_in_delta alder_p.runway_hours, 10_000 / hourly_micro(@fixture_monthly_cents), 0.01
      assert_in_delta birch_p.runway_hours, 50_000 / hourly_micro(@fixture_monthly_cents), 0.01
    end

    test "a spent wallet with nothing burning counts depleted, never low", %{admin: admin} do
      before = AdminHealth.runway(admin)

      # The billing page's spent shape: funded, then debited past zero,
      # and no instances — balance < 0 with :infinity runway. The
      # escapee the hours alone would drop into silence.
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, wallet} = Billing.ensure_wallet(org)
      {:ok, _grant} = Billing.grant_credits(wallet, 10_000, reason: :adjustment)
      {:ok, _debit} = Billing.debit_wallet(wallet, 200_000_000)

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets + 1
      assert runway.depleted == before.depleted + 1
      assert runway.low == before.low
      assert runway.unknown == before.unknown
      assert org.name == "billing-fixture"
    end

    # The gate-truth pin, stated: the admin-only refusal lives in the
    # org-name lookup, which a member with no visible wallets never
    # reaches — this corner returns the zeroed map. No caller may read
    # the seam as an auth check; the route gate is the auth check.
    test "a member with no visible wallets gets the zeroed map, not Forbidden" do
      {org, owner} = BillingFixtures.grant_free_org!()

      runway = AdminHealth.runway(owner)

      assert runway.wallets == 0
      assert runway.low == []
      assert runway.unknown == 0
      assert runway.depleted == 0
      assert runway.unavailable == false
      assert runway.threshold_hours == 168
      assert org.name == "billing-fixture"
    end

    test "a burn-free wallet never reads low", %{admin: admin} do
      before = AdminHealth.runway(admin)

      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets + 1
      assert runway.low == before.low
      assert runway.unknown == before.unknown
      assert runway.depleted == before.depleted
    end

    test "the gate is the configured threshold, not a constant", %{admin: admin} do
      # Capture-and-restore (the stub_build_sha posture): the override
      # moves the gate below the fixture's ≈ 5.2h of runway.
      original = Application.get_env(:flux_vale, :low_runway_hours)
      Application.put_env(:flux_vale, :low_runway_hours, 1)

      on_exit(fn ->
        if original == nil do
          Application.delete_env(:flux_vale, :low_runway_hours)
        else
          Application.put_env(:flux_vale, :low_runway_hours, original)
        end
      end)

      before = AdminHealth.runway(admin)
      {_org, _wallet} = burning_wallet!()

      runway = AdminHealth.runway(admin)

      assert runway.threshold_hours == 1
      assert runway.wallets == before.wallets + 1
      # The same fixture that reads low under the default 168 sits
      # above a 1h gate.
      assert runway.low == before.low
    end

    test "the org lookup batches past the #501 action's 200-id cap", %{admin: admin} do
      before = AdminHealth.runway(admin)

      # Bulk volume — the sanctioned Ash.Seed escape. 201 orgs with
      # wallets push the :admin_lookup ask past its 200-id constraint
      # (the shape a shared dev DB hit live; beta production stays
      # under it). Zero balances: :infinity never reads low, so only
      # the wallet count moves.
      for i <- 1..201 do
        Ash.Seed.seed!(Organization, %{
          name: "bulk-org-#{i}-#{@n}",
          slug: "bulk-org-#{i}-#{@n}",
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

        Ash.Seed.seed!(Wallet, %{
          organization_id: Organization.get_by_slug!("bulk-org-#{i}-#{@n}", authorize?: false).id,
          carryover: 0,
          paywall_waived: false,
          created_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })
      end

      # The burning wallet is created AFTER the 201 seeds, so its org's
      # uuid sorts into the SECOND chunk — its row naming the org
      # proves the chunk assembly, not just the absence of a 500.
      {org, _wallet} = burning_wallet!(name: "Chunk Two Burner")

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets + 202
      assert runway.unknown == before.unknown

      assert [%{org: "Chunk Two Burner", slug: slug, projection: projection}] =
               runway.low -- before.low

      assert slug == org.slug

      assert_in_delta projection.runway_hours, 10_000 / hourly_micro(@fixture_monthly_cents), 0.01
    end

    test "an errored projection counts unknown, never low", %{admin: admin} do
      # One wallet of this test's own so `unknown >= 1` is scoped to
      # something the test controls.
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)

      before = AdminHealth.runway(admin)

      # The error arm is the projection's defensive posture (a resolver
      # read failure is data corruption, per the operation) — stubbed
      # at the defdelegate's target because no constraint-respecting
      # fixture can produce it.
      Mimic.copy(FluxVale.Billing.Operations.ComputeRunway)

      stub(FluxVale.Billing.Operations.ComputeRunway, :call, fn _wallet ->
        {:error, :projection_dead}
      end)

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets
      assert runway.unknown == before.wallets
      assert runway.unknown >= 1

      # With every projection errored, nothing can read low — the empty
      # list is the only correct expectation, whatever the partition
      # carries.
      assert runway.low == []
    end

    # The operation's bang reads sit outside its error-returning with,
    test "a failed widget read degrades to unavailable, never Forbidden", %{admin: admin} do
      # The wallet read + name lookup are the widget's one unguarded
      # surface: an infrastructure failure there lands the widget in
      # its unavailable shape (the panel says so) instead of taking
      # the page down. The lookup is the stubbable boundary — an exit
      # rides the wrapper's catch arm the same way a raise rides its
      # rescue.
      Mimic.copy(Ash)

      stub(Ash, :run_action!, fn _input ->
        exit(:lookup_down)
      end)

      runway = AdminHealth.runway(admin)

      assert runway.unavailable == true
      assert runway.low == []
      assert runway.wallets == 0
      assert runway.unknown == 0
      assert runway.depleted == 0
    end

    test "a projection that raises or exits counts unknown, never the page down", %{
      admin: admin
    } do
      # so a read failure arrives as a raise (or an exit — the wake
      # wrapper's same shape); the wrapper answers both with unknown.
      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)
      Mimic.copy(FluxVale.Billing.Operations.ComputeRunway)

      stub(FluxVale.Billing.Operations.ComputeRunway, :call, fn _wallet ->
        raise "projection read blew up"
      end)

      runway = AdminHealth.runway(admin)
      assert runway.unknown == runway.wallets
      assert runway.low == []

      stub(FluxVale.Billing.Operations.ComputeRunway, :call, fn _wallet ->
        exit(:projection_dead)
      end)

      after_exit = AdminHealth.runway(admin)
      assert after_exit.unknown == after_exit.wallets
      assert after_exit.low == []
    end
  end

  describe "audit_activity/1" do
    test "counts action-created rows and sorts the top five desc", %{admin: admin} do
      # Four trail-only rows across distinct resources guarantee >5
      # active entries even on a clean partition, so the total-vs-capped
      # arm below is meaningful without relying on committed strays.
      seed_extra_activity!()

      before = AdminHealth.audit_activity(admin)

      # `fourth + 1` puts a fixture count above every pre-existing count
      # but the top three, so at most four rows can outrank the flag row
      # and both fixtures stay inside the top-5 cap; committed partition
      # strays can never hide them. A clean partition's fourth is zero,
      # so the fixtures start at one flag and two tags.
      fourth =
        before.top
        |> Enum.at(3)
        |> then(&(&1 && &1.count)) || 0

      for i <- 1..(fourth + 1), do: flag!(admin, "#{i}")
      for i <- 1..(fourth + 2), do: tag!(admin, "c4_tag_#{i}_#{@n}")

      after_activity = AdminHealth.audit_activity(admin)

      assert after_activity.total == before.total + (fourth + 1) + (fourth + 2)
      assert length(after_activity.top) <= 5

      counts = Enum.map(after_activity.top, & &1.count)
      assert counts == Enum.sort(counts, :desc)

      # More than five active resources, so the capped rows cannot carry
      # the whole total — the active count is the overflow line's source.
      top_total =
        after_activity.top
        |> Enum.map(& &1.count)
        |> Enum.sum()

      assert after_activity.active > 5
      assert after_activity.total > top_total

      assert ff = Enum.find(after_activity.top, &(&1.key == :feature_flag))
      assert tag_row = Enum.find(after_activity.top, &(&1.key == :tag))
      assert ff.count > fourth
      assert tag_row.count > fourth
      assert ff.label == "Feature flag"
      assert tag_row.label == "Tag"
    end

    test "ties sort by resource key ascending", %{admin: admin} do
      before = AdminHealth.audit_activity(admin)

      # `ceiling + 1` clears every pre-existing count, so the tied set is
      # exactly the two fixtures — equal counts, entry-key order.
      ceiling =
        before.top
        |> List.first()
        |> then(&(&1 && &1.count)) || 0

      for i <- 1..(ceiling + 1), do: flag!(admin, "tie_#{i}")
      for i <- 1..(ceiling + 1), do: tag!(admin, "c4_tie_tag_#{i}_#{@n}")

      after_activity = AdminHealth.audit_activity(admin)

      tied = Enum.filter(after_activity.top, &(&1.count == ceiling + 1))
      assert Enum.map(tied, & &1.key) == [:feature_flag, :tag]
    end

    test "excludes rows older than 24h", %{admin: admin} do
      before = AdminHealth.audit_activity(admin)

      # Ash.Seed is the sanctioned bypass: the paper trail only stamps
      # "now", so the window's boundary needs a hand-shaped row.
      Ash.Seed.seed!(FeatureFlag.Version, %{
        version_action_type: :create,
        version_action_name: :create,
        version_action_inputs: %{},
        version_source_id: Ecto.UUID.generate(),
        actor_label: "old",
        version_inserted_at: DateTime.add(DateTime.utc_now(), -25, :hour),
        changes: %{}
      })

      assert AdminHealth.audit_activity(admin).total == before.total

      flag!(admin, "fresh")
      assert AdminHealth.audit_activity(admin).total == before.total + 1
    end

    test "the seam is admin-only — a member actor and a nil actor are Forbidden" do
      # The version tables' direct admin-only read policy is the
      # refusal (ADR-0048 D7 — the fleet trail's same pin).
      member = AccountsFixtures.user!()

      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.audit_activity(member) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.audit_activity(nil) end
    end

    test "top rows are positive", %{admin: admin} do
      for row <- AdminHealth.audit_activity(admin).top, do: assert(row.count > 0)
    end
  end

  # A running, cluster-managed instance — the approve gate's legal
  # status and the storage machinery's precondition.
  defp running_deployed!(version, user) do
    created =
      Instance.create!(
        %{
          name: "Storage #{System.unique_integer([:positive])}",
          app_version_id: version.id,
          env_vars: %{}
        },
        actor: user
      )

    running = InstanceFixtures.walk_to!(created, :running)
    InstanceFixtures.pin!(running, namespace: "fluxvale-app-#{created.id}")
  end

  # The expected runway arithmetic: the balance in µ¢ over `monthly_cents`,
  # divided the projection's own way over Billing.Month's average
  # Gregorian month (the one constant — its moduledoc forbids forks).
  defp hourly_micro(monthly_cents) do
    div(monthly_cents * 10_000 * 3600, Month.seconds())
  end

  # The burning-wallet fixture: a grant-free org's wallet funded to
  # exactly `balance` cents through the posting action, its owner's
  # instance walked to :running on the fixture version — 140¢/mo of
  # burn (the compute class plus the 10 GB storage axis). `name`
  # renames the org: every grant-free org shares one fixture name,
  # and the widget renders the name.
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

  # Four trail-only rows across distinct resources guarantee >5 active
  # entries even on a clean partition. Ash.Seed is the sanctioned bypass
  # for fabricated version rows (the fleet deploy trail's same posture):
  # this test needs controlled count coverage, not four unrelated action
  # contracts.
  defp seed_extra_activity! do
    for version_module <- [Category.Version, Cluster.Version, Size.Version, TaxRate.Version] do
      Ash.Seed.seed!(version_module, %{
        version_action_type: :create,
        version_action_name: :create,
        version_action_inputs: %{},
        version_source_id: Ecto.UUID.generate(),
        actor_label: "c4-extra",
        version_inserted_at: DateTime.utc_now(),
        changes: %{}
      })
    end
  end
end
