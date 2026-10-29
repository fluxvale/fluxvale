defmodule FluxVale.Identity.UserEmail.HealSetPrimaryConcurrencyTest do
  @moduledoc """
  The heal-vs-SetPrimary race under true concurrency (round-3 verdict,
  P2): conn A promotes the account's verified second address via the
  production `SetPrimary` action, holding the user-row FOR UPDATE lock
  UNCOMMITTED; conn B signs in through `Identity.verify_auth_code/2`
  for the old-pod signup address. B's JIT create collides and the heal
  writes the mirror row — and its `is_primary` decision must be taken
  INSIDE the transaction, after EnforceEmailCap's FOR UPDATE on the
  same user row: the count then sees A's committed promotion and
  attaches the signup row NON-primary. A decision taken before the
  transaction opens (the round-3 defect) reads 0 primaries, forces
  `is_primary=true`, and walks into the at-most-one-primary partial
  index — first attempt `{:error, :address_unresolved}`, one burned
  code.

  Synchronization is lock ordering plus scoped repo telemetry — no
  sleeps:

  * A's lock is confirmed (`{:locked_a}` received) before B ever
    starts, so the promotion is always mid-flight when B decides;
  * A commits on the FIRST repo query proving B's heal passed its
    decision point: the takes-primary count itself (decision outside
    the transaction — it runs pre-`begin`), or the heal transaction's
    `begin` directly after B's read of the owner row (decision inside
    the transaction — `begin` is the last statement before the
    blocked user-row lock). Either way the count provably ran before
    A's commit;
  * both arms are scoped to this test's own rows via telemetry params
    (the user uuid / signup address), so the suite's concurrent async
    tests — which run the same queries for their own rows — cannot
    arm them.
  """

  use FluxVale.DataCase, async: false

  import FluxVale.TestSupport.AuthCodeHelpers, only: [mailbox_code: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Repo

  require Ash.Query

  @receive_timeout 15_000
  @repo_query [:flux_vale, :repo, :query]

  test "a heal racing a concurrent SetPrimary signs in on the first attempt — the primary decision serializes on the user-row lock" do
    %{user: user, promoted: promoted, address: address, code: code} = seeded!()
    on_exit(fn -> cleanup!([user.id], address) end)

    parent = self()

    # classifies B's query stream for the watcher; adjacency (the arm
    # on `begin`) is tracked by the watcher process, not here — the
    # classifier runs in whichever process emits the query and must
    # stay stateless
    watcher = spawn(fn -> watch(false, parent) end)

    handler_id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      handler_id,
      @repo_query,
      &classify/4,
      %{watcher: watcher, parent: parent, user_uuid: Ecto.UUID.dump!(user.id), address: address}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # conn A: the production promotion inside an OPEN transaction — the
    # user-row lock is held, the promotion invisible, until told to commit
    promoter =
      spawn(fn ->
        conn = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.transaction(fn ->
            assert {:ok, _promoted} = UserEmail.set_primary(promoted, authorize?: false)

            send(parent, {:locked_a, self()})

            receive do
              :commit -> :ok
            after
              15_000 -> Repo.rollback(:never_told_to_commit)
            end
          end)

          send(parent, {:committed_a, self()})
        after
          Sandbox.checkin(Repo, conn)
        end
      end)

    # order: the promotion holds the lock, THEN the sign-in runs —
    # the heal's decision point is provably crossed before A commits
    assert_receive {:locked_a, _}, @receive_timeout

    spawn(fn ->
      conn = Sandbox.checkout(Repo, sandbox: false)

      try do
        send(parent, {:done_b, Identity.verify_auth_code(address, code)})
      after
        Sandbox.checkin(Repo, conn)
      end
    end)

    # B's heal reached its decision point (the watcher's begin-arm, or
    # the count itself when it runs outside the transaction)
    decision_point =
      receive do
        {:arm, point} -> point
      after
        @receive_timeout -> :unobserved
      end

    send(promoter, :commit)

    # FIRST attempt: no burned code, no retry
    assert_receive {:done_b, verify_result}, @receive_timeout
    assert {:ok, signed_in, token} = verify_result
    assert signed_in.id == user.id
    assert is_binary(token) and token != ""

    assert_receive {:committed_a, _}, @receive_timeout

    # exactly one primary — the promotion kept it — and the healed
    # signup row is verified but non-primary
    rows = rows_for(user.id)
    assert length(rows) == 2
    assert Enum.count(rows, & &1.is_primary) == 1
    assert Enum.any?(rows, &(&1.id == promoted.id and &1.is_primary))

    assert %{is_primary: false, verified_at: verified_at} =
             Enum.find(rows, &(to_string(&1.address) == to_string(address)))

    refute is_nil(verified_at)

    # the decision was taken inside the transaction — B's heal begin
    # preceded its primary count (a pre-transaction count arms as
    # :counted and the first-attempt assertion above already failed).
    # :unobserved means concurrent async traffic broke the adjacency
    # while B was blocked; the commit-anyway guard kept every outcome
    # assertion above meaningful, so only the arm shape is unproven.
    assert decision_point in [:begin, :unobserved]
  end

  # Telemetry classifier: forwards only the query classes the handshake
  # needs, scoped to this test's rows. Runs in the emitting process —
  # stateless, and it must never raise.
  defp classify(
         _event,
         _measurements,
         meta,
         %{watcher: watcher, parent: parent, user_uuid: user_uuid, address: address}
       ) do
    sql = meta[:query] || ""
    params = meta[:params] || []

    cond do
      primary_count?(sql, params, user_uuid) ->
        send(parent, {:arm, :counted})

      owner_read?(sql, params, address) ->
        send(watcher, {:users_mine})

      sql == "begin" ->
        send(watcher, {:begin})

      true ->
        send(watcher, {:other})
    end
  end

  # The takes-primary count carries this test's user uuid as a param;
  # the cap count shares the table but not the is_primary filter.
  defp primary_count?(sql, params, user_uuid) do
    String.contains?(sql, "count") and
      String.contains?(sql, ~s("user_emails")) and
      String.contains?(sql, "is_primary") and
      Enum.any?(params, &(&1 == user_uuid))
  end

  defp owner_read?(sql, params, address) do
    String.starts_with?(sql, "SELECT") and
      String.contains?(sql, ~s(FROM "users")) and
      Enum.any?(params, &(&1 == address))
  end

  # Adjacency state for the begin-arm: only a begin DIRECTLY following
  # B's owner read proves the heal transaction opened — the JIT
  # create's begin follows its own users-by-username probe instead.
  defp watch(true, parent) do
    receive do
      {:begin} -> send(parent, {:arm, :begin})
      {:users_mine} -> watch(true, parent)
      {:other} -> watch(false, parent)
    end
  end

  defp watch(false, parent) do
    receive do
      {:users_mine} -> watch(true, parent)
      {:begin} -> watch(false, parent)
      {:other} -> watch(false, parent)
    end
  end

  # Seeds through a committed (non-sandboxed) connection so both racing
  # connections see the rows: the old-pod shape (users.email set, no
  # user_emails row — seed! is the sanctioned bypass), a verified
  # second address to promote, and a live code for the signup address.
  defp seeded! do
    committed?(fn ->
      unique = System.unique_integer([:positive])
      address = "heal-race-#{unique}@fluxvale.test"

      user = Ash.Seed.seed!(User, %{email: address})

      {:ok, pending} =
        UserEmail.add("heal-race-x-#{unique}@fluxvale.test", %{user: user}, authorize?: false)

      {:ok, promoted} = UserEmail.mark_verified(pending, authorize?: false)
      assert :ok = Identity.request_auth_code(address)
      code = mailbox_code()

      %{user: user, promoted: promoted, address: address, code: code}
    end)
  end

  # Runs fun on a real connection whose writes commit immediately. Works
  # from on_exit too — sandbox:false checkouts bypass sandbox ownership.
  defp committed?(fun) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  defp rows_for(user_id) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
  end

  # Removes the committed rows — the sandbox never owned them. The seed!
  # owner provisioned no org, but a successful sign-in mints a token.
  defp cleanup!(user_ids, address) do
    committed?(fn ->
      dumped = Enum.map(user_ids, &Ecto.UUID.dump!/1)
      subjects = Enum.map(user_ids, &"user?id=#{&1}")

      Repo.query!("DELETE FROM user_emails WHERE user_id = ANY($1)", [dumped])
      Repo.query!("DELETE FROM auth_codes WHERE email::text = ANY($1)", [[address]])
      Repo.query!("DELETE FROM tokens WHERE subject = ANY($1)", [subjects])
      Repo.query!("DELETE FROM users WHERE id = ANY($1)", [dumped])
    end)
  end
end
