defmodule FluxVale.Edge.ActivityTest do
  @moduledoc false

  # The debounce (#203): one last_used_at write per window per instance,
  # however hot the edge. Synchronous marks — no test sleeps.

  # async: false — the Activity GenServer is the app's one named
  # process; its DB writes must see this test's sandbox (shared mode),
  # and its ETS windows are global state.
  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Edge.Activity
  alias FluxVale.Identity.User
  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Repo
  alias FluxVale.TestSupport.InstanceFixtures

  # The app's supervision tree already runs the GenServer; tests reuse
  # it (mark/1 is a named call). The sandbox owner must cover its DB
  # writes (they happen in the GenServer's process, not the test's).
  setup do
    Sandbox.allow(Repo, self(), Process.whereis(Activity))
    :ok
  end

  defp instance! do
    version = InstanceFixtures.app_version!()
    InstanceFixtures.local_cluster!()

    Instance.create!(
      %{name: "App", app_version_id: version.id, env_vars: %{}},
      actor: User.create!("act-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
    )
  end

  test "the first mark writes the clock; the one after debounces" do
    instance = instance!()

    assert {:ok, :marked} = Activity.mark(instance.id)
    assert {:ok, :debounced} = Activity.mark(instance.id)

    touched = Instance.get_by_id!(instance.id, authorize?: false)
    assert touched.last_used_at
  end

  test "a stale instance id answers :error — the beacon still 204s" do
    ghost = "00000000-0000-7000-8000-000000000000"

    assert {:error, _reason} = Activity.mark(ghost)
  end

  # The steady-state hot-traffic path is the window arithmetic: a
  # marker older than the window no longer debounces (the table is
  # owner-writable only — serialized claims — so the lapsed arm is
  # unit-tested here rather than staged through the GenServer).
  test "a lapsed window no longer debounces; a fresh one does" do
    now = System.monotonic_time(:second)

    refute Activity.window_open?(now, nil)
    refute Activity.window_open?(now, now - 120)
    assert Activity.window_open?(now, now)
  end

  test "a wedged server answers :error/:proceed — the beacon still 204s" do
    # Suspend the named server: calls queue past mark's 1s timeout, and
    # the catch arms answer per the beacon contract. Resume drains.
    pid = Process.whereis(Activity)
    :sys.suspend(pid)

    assert {:error, :overloaded} = Activity.mark("00000000-0000-7000-8000-000000000000")
    assert :proceed = Activity.claim_restore("restore-after-restart")
    assert :proceed = Activity.claim_access_flip("flip-after-restart")

    :sys.resume(pid)
    _state = :sys.get_state(pid)
  end

  test "a malformed id is an error tuple, not a crash" do
    assert {:error, _reason} = Activity.mark("not-a-uuid")
  end

  test "claim_restore proceeds once per window" do
    key = "restore-#{System.unique_integer()}"

    assert :proceed = Activity.claim_restore(key)
    assert :throttled = Activity.claim_restore(key)
  end

  # #273: the access wake's flip debounce — same window, own claim key:
  # the restore and the flip are two different applies, and neither may
  # starve the other's window.
  test "claim_access_flip proceeds once per window, independent of claim_restore" do
    id = "flip-#{System.unique_integer()}"

    assert :proceed = Activity.claim_access_flip(id)
    assert :throttled = Activity.claim_access_flip(id)

    # Same instance, different claim key: the restore's window is its own.
    assert :proceed = Activity.claim_restore(id)
    assert :throttled = Activity.claim_restore(id)
  end
end
