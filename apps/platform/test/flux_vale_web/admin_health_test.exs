defmodule FluxValeWeb.AdminHealthTest do
  @moduledoc false

  # The Health section's widget seam (#702): fleet/1 through the real
  # reads. The partition DB carries committed instance strays from
  # other lanes, so every count asserts a DELTA around this test's own
  # writes — the exact discipline the audit section's tests ride (#241).
  # The module is sync because one test manipulates the app env (the
  # capture-and-restore posture); ExUnit runs sync modules alone.

  use FluxVale.DataCase, async: false

  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.TestSupport.AccountsFixtures
  alias FluxVale.TestSupport.InstanceFixtures
  alias FluxValeWeb.AdminHealth

  @n :erlang.unique_integer([:positive])

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
      pending = InstanceFixtures.instance!(version, member)
      running = InstanceFixtures.instance!(version, member)
      always_on = InstanceFixtures.walk_to!(running, :running)

      Instance.set_always_on!(always_on, %{always_on: true}, actor: member)

      fleet = AdminHealth.fleet(admin)

      assert fleet.total == before.total + 2
      assert fleet.statuses[:pending] == (before.statuses[:pending] || 0) + 1
      assert fleet.statuses[:running] == (before.statuses[:running] || 0) + 1
      assert fleet.always_on == before.always_on + 1
      assert pending.status == :pending
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
      # stay out of the trail.
      Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
        version_action_type: :create,
        version_action_name: :create,
        version_action_inputs: %{},
        version_source_id: source,
        actor_label: "creator",
        version_inserted_at: base,
        changes: %{}
      })

      deploys = AdminHealth.fleet(admin).recent_deploys

      assert length(deploys) == 5
      assert [%{actor: "deployer-6"} = newest | rest] = deploys

      assert Enum.map(rest, & &1.actor) == [
               "deployer-5",
               "deployer-4",
               "deployer-3",
               "deployer-2"
             ]

      assert newest.source == String.slice(source, 0, 8)

      # Newest first on the version's own stamp.
      stamps = Enum.map(deploys, & &1.at)
      assert stamps == Enum.sort(stamps, {:desc, DateTime})

      # A nil tombstone maps through untouched (the widget renders the
      # System attribution, not this seam).
      nil_row =
        Ash.Seed.seed!(FluxVale.Infrastructure.Instance.Version, %{
          version_action_type: :update,
          version_action_name: :deploy,
          version_action_inputs: %{},
          version_source_id: source,
          actor_label: nil,
          version_inserted_at: DateTime.add(base, 7 * 60, :second),
          changes: %{}
        })

      assert [latest] = Enum.take(AdminHealth.fleet(admin).recent_deploys, 1)
      assert latest.actor == nil_row.actor_label
      assert latest.at == nil_row.version_inserted_at
    end

    test "the build stamp passes env and version through", %{admin: admin} do
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

      Application.put_env(:flux_vale, :platform_env, original)
      assert AdminHealth.fleet(admin).version == FluxVale.Build.version()
    end
  end
end
