defmodule FluxVale.Api.Operations.BumpRequestWindowConcurrencyTest do
  @moduledoc """
  The upsert-increment's lost-update proof (#360 slice 3): concurrent
  bumps on one `{token, window}` must total exactly the number of
  bumps — a read-modify-write would drop some under contention.

  Uses `Sandbox.checkout(_, sandbox: false)` connections (the
  DebitWalletConcurrency posture): the counter row must be committed
  for every writer to see it, so the MERGE contention is genuine. The
  test cleans up its own committed rows before finishing.
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Api
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Repo

  @bumps 8

  test "concurrent bumps lose nothing — the max equals the bump count" do
    %{pat_id: pat_id} = seeded!()

    on_exit(fn -> cleanup!(pat_id) end)

    parent = self()
    window = DateTime.utc_now(:second)

    workers =
      for n <- 1..@bumps do
        spawn(fn ->
          conn = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, n})

          count =
            receive do
              :go -> Api.bump_request_window(pat_id, window)
            end

          Sandbox.checkin(Repo, conn)
          send(parent, {:done, n, count})
        end)
      end

    # every writer holds a real connection before any bumps — the
    # conflict is genuine, not a race we happen to win
    Enum.each(1..@bumps, fn _round -> assert_receive {:ready, _n}, 5_000 end)
    Enum.each(workers, fn pid -> send(pid, :go) end)

    counts =
      Enum.map(1..@bumps, fn _round ->
        assert_receive {:done, _n, count}, 5_000
        count
      end)

    # no lost increments: the highest count seen is every bump, and
    # the committed row agrees
    assert Enum.max(counts) == @bumps
    assert committed_count!(pat_id) == @bumps
  end

  # Seeds the PAT on a committed connection so every worker sees it.
  defp seeded! do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      user = User.create!("bump-concurrency@fluxvale.com", %{}, authorize?: false)

      {:ok, %{pat: pat}} =
        Identity.mint_pat(nil, %{user_id: user.id, name: "concurrency", scopes: []},
          authorize?: false
        )

      %{pat_id: pat.id}
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  defp committed_count!(pat_id) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      # one window per token in this test — the token alone keys the
      # row; raw SQL params need uuids as 16-byte binaries
      result =
        Repo.query!("SELECT count FROM request_windows WHERE token_id = $1", [
          Ecto.UUID.dump!(pat_id)
        ])

      [[count]] = result.rows
      count
    after
      Sandbox.checkin(Repo, conn)
    end
  end

  # Removes the committed rows — the sandbox never owned them. The
  # PAT cascade would take the windows, but each table goes explicitly
  # (FK order); user teardown covers the rest (emails, memberships,
  # the JIT personal org's billing rows — the DebitWallet shape).
  defp cleanup!(pat_id) do
    conn = Sandbox.checkout(Repo, sandbox: false)

    try do
      # Raw SQL params need uuids as 16-byte binaries (Ecto.UUID.dump!/1).
      pat_uuid = Ecto.UUID.dump!(pat_id)

      [[user_id]] =
        Repo.query!("SELECT user_id FROM personal_access_tokens WHERE id = $1", [pat_uuid]).rows

      org_ids =
        Repo.query!("SELECT organization_id FROM memberships WHERE user_id = $1", [user_id]).rows

      Repo.query!("DELETE FROM request_windows WHERE token_id = $1", [pat_uuid])

      Repo.query!(
        "DELETE FROM billing_ledger_entries WHERE wallet_id IN (SELECT id FROM billing_wallets WHERE organization_id = ANY($1))",
        [org_ids]
      )

      Repo.query!("DELETE FROM billing_wallets WHERE organization_id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM user_emails WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM memberships WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [org_ids])
      Repo.query!("DELETE FROM personal_access_tokens WHERE user_id = $1", [user_id])
      Repo.query!("DELETE FROM users WHERE id = $1", [user_id])
    after
      Sandbox.checkin(Repo, conn)
    end
  end
end
