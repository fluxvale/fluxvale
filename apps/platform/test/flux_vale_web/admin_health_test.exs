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
  alias FluxVale.Billing.Wallet
  alias FluxVale.Clients.K8s
  alias FluxVale.Clients.K8s.Resources.StorageClass
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.StorageRequest
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.BillingFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxVale.TestSupport.StorageRequestFixtures
  alias FluxValeWeb.AdminAudit
  alias FluxValeWeb.AdminHealth

  @n :erlang.unique_integer([:positive])

  # The runway arithmetic's fixture constants: the version fixture's
  # compute rate plus its 10 GB storage axis = 140¢/mo, divided the
  # projection's way (µ¢/h over Billing.Month's average Gregorian
  # month — the same shape the ComputeRunway tests pin).
  @month_seconds 2_629_746
  @fixture_monthly_cents 140
  @fixture_hourly_micro div(@fixture_monthly_cents * 10_000 * 3600, @month_seconds)

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

    # The admin-only pin: the queue read is the refusing policy for a
    # member (the instance read admits them org-scoped), the instance
    # read for a nil actor — either way the seam raises the Forbidden.
    test "the seam is admin-only — a member actor and a nil actor are Forbidden" do
      member = AccountsFixtures.user!()

      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.storage(member) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.storage(nil) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.runway(member) end
      assert_raise Ash.Error.Forbidden, fn -> AdminHealth.runway(nil) end
    end
  end

  describe "runway/1" do
    test "a wallet under the gate reads low with its org's name and hours", %{admin: admin} do
      before = AdminHealth.runway(admin)
      {org, _wallet} = burning_wallet!()

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets + 1
      assert runway.unknown == before.unknown
      # The owner's gate: one week, until configured otherwise.
      assert runway.threshold_hours == 168
      assert length(runway.low) == length(before.low) + 1

      # 1¢ against 140¢/mo of burn: the projection's own figure, 10_000
      # µ¢ ÷ 1916 µ¢/h — the float the widget renders.
      new_rows = runway.low -- before.low
      assert [%{org: name, hours: hours}] = new_rows
      assert name == org.name
      assert_in_delta hours, 10_000 / @fixture_hourly_micro, 0.01
    end

    test "a burn-free wallet never reads low", %{admin: admin} do
      before = AdminHealth.runway(admin)

      {org, _owner} = BillingFixtures.grant_free_org!()
      {:ok, _wallet} = Billing.ensure_wallet(org)

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets + 1
      assert runway.low == before.low
      assert runway.unknown == before.unknown
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
      {org, _wallet} = burning_wallet!()

      runway = AdminHealth.runway(admin)

      assert runway.threshold_hours == 1
      assert runway.wallets == before.wallets + 1
      # The same fixture that reads low under the default 168 sits
      # above a 1h gate.
      assert runway.low == before.low
      assert org.name == "billing-fixture"
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

      runway = AdminHealth.runway(admin)

      assert runway.wallets == before.wallets + 201
      assert runway.low == before.low
      assert runway.unknown == before.unknown
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
      assert runway.low == before.low
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

  # The burning-wallet fixture: a grant-free org's wallet funded to
  # exactly 1¢ through the posting action, its owner's instance walked
  # to :running on the fixture version — 140¢/mo of burn (the compute
  # class plus the 10 GB storage axis) against a 1¢ balance.
  defp burning_wallet! do
    version = InstanceFixtures.app_version!(monthly_cents: 100, default_storage_gb: 10)
    {org, owner} = BillingFixtures.grant_free_org!()
    {:ok, wallet} = Billing.ensure_wallet(org)
    {:ok, _grant} = Billing.grant_credits(wallet, 1, reason: :adjustment)

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
end
