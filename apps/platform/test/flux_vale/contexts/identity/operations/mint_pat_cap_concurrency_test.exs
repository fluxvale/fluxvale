defmodule FluxVale.Identity.Operations.MintPatCapConcurrencyTest do
  @moduledoc """
  The derived-token cap under true concurrency (#772): the count and
  the insert must be one per-user critical section. With the cap one
  slot from full, simultaneous mints must land exactly one row — a
  check-then-insert without the user-row lock lets every worker read
  the same pre-cap count and all of them insert.

  Uses `Sandbox.checkout(_, sandbox: false)` connections (the
  DebitWalletConcurrency posture): the seed rows must be committed
  for every writer to see them, so the lock contention is genuine.
  The test cleans up its own committed rows before finishing.
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Identity
  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.PersonalAccessToken.EnforceDerivedTokenCap
  alias FluxVale.Identity.User
  alias FluxVale.Repo

  # Real connections are scarce (the pool is schedulers × 2): the
  # test's own sandbox checkout plus three writers fit the floor, and
  # two simultaneous writers already prove the arbiter.
  @workers 3

  test "concurrent mints cannot exceed the cap" do
    %{user_id: user_id, parent_id: parent_id} = seeded!()

    on_exit(fn -> cleanup!(user_id) end)

    parent = self()

    workers =
      for n <- 1..@workers do
        spawn(fn ->
          conn = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, n})

          result =
            try do
              receive do
                :go -> mint(user_id, parent_id, "race #{n}")
              after
                5_000 -> :timeout
              end
            after
              # a crash between checkout and checkin must not leak the
              # connection for the rest of the suite
              Sandbox.checkin(Repo, conn)
            end

          send(parent, {:done, n, result})
        end)
      end

    # every writer holds a real connection before any mint — the lock
    # contention is genuine, not a race we happen to win
    Enum.each(workers, fn _worker -> assert_receive {:ready, _n}, 5_000 end)
    Enum.each(workers, fn worker -> send(worker, :go) end)

    results =
      Enum.map(1..@workers, fn _n ->
        assert_receive {:done, _n, result}, 10_000
        result
      end)

    assert Enum.count(results, &match?({:ok, _minted}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :too_many_live_tokens})) == @workers - 1

    assert PersonalAccessToken.count_live_derived!(user_id, DateTime.utc_now()) ==
             EnforceDerivedTokenCap.max_live_derived_tokens()
  end

  # Seeds one root plus cap-minus-one live children on a committed
  # connection, so every worker starts one slot from the cap.
  defp seeded! do
    committed(fn ->
      unique = System.unique_integer([:positive])

      user =
        User.create!("cap-race-#{unique}@fluxvale.test", %{}, authorize?: false)

      {:ok, %{pat: root}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "root", scopes: []}, authorize?: false)

      for n <- 1..(EnforceDerivedTokenCap.max_live_derived_tokens() - 1) do
        {:ok, _minted} =
          Identity.mint_pat(
            nil,
            %{
              user_id: user.id,
              name: "seed #{n}",
              scopes: [],
              metadata: %{"minted_parent_id" => root.id}
            },
            authorize?: false
          )
      end

      %{user_id: user.id, parent_id: root.id}
    end)
  end

  defp mint(user_id, parent_id, name) do
    Identity.mint_pat(
      nil,
      %{
        user_id: user_id,
        name: name,
        scopes: [],
        metadata: %{"minted_parent_id" => parent_id}
      },
      authorize?: false
    )
  end

  # Runs fun on a real connection whose writes commit immediately.
  # Works from on_exit too — sandbox:false checkouts bypass ownership.
  defp committed(fun) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Removes the committed rows — the sandbox never owned them. Raw SQL
  # params need uuids as 16-byte binaries (Ecto.UUID.dump!/1); the
  # token audit rows and the JIT personal org's billing chain go with
  # their owners (the BumpRequestWindow cleanup shape).
  defp cleanup!(user_id) do
    committed(fn ->
      dumped = Ecto.UUID.dump!(user_id)

      org_ids =
        Repo.query!("SELECT organization_id FROM memberships WHERE user_id = $1", [dumped]).rows

      org_ids = Enum.map(org_ids, &hd/1)

      Repo.query!(
        "DELETE FROM billing_ledger_entries WHERE wallet_id IN (SELECT id FROM billing_wallets WHERE organization_id = ANY($1))",
        [org_ids]
      )

      Repo.query!("DELETE FROM billing_wallets WHERE organization_id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM personal_access_tokens WHERE user_id = $1", [dumped])
      Repo.query!("DELETE FROM user_emails WHERE user_id = $1", [dumped])
      Repo.query!("DELETE FROM memberships WHERE user_id = $1", [dumped])
      Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM users WHERE id = $1", [dumped])
    end)
  end
end
