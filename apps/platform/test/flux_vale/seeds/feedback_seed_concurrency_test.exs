defmodule FluxVale.Seeds.FeedbackSeedConcurrencyTest do
  @moduledoc """
  The #508 concurrency proofs: every feedback mint site carries a DB
  identity now (post slug, vote per org, comment per (post, author,
  body) triple, commenter email, voter org slug), so two racing
  seeders converge — the loser of each mint catches the unique
  violation and re-finds the winner's committed row. Before #508 the
  comment triple had no identity: two concurrent seeding runs both
  found zero comments and both minted, and the duplicate then failed
  every later seed pass on the corruption guard.

  Two layers here:

  - The end-to-end race: two full `seed_feedback!` runs against one
    database — the issue's acceptance. Which racer loses which mint is
    timing, not substance; the assertions read only the converged state.

  - The per-site harness: a held-uncommitted row carrying a site's
    exact identity stages the race window deterministically. The
    seeder's find cannot see the held row (snapshot), its mint cannot
    bypass it (the unique index waits on the held insertion), and the
    harness release commit turns the wait into the violation. One test
    per mint site, so every loser arm is exercised without depending
    on wall-clock interleaving. The seeded pass rides a committed
    connection in the harness tests — the test's sandbox transaction
    must hold no row locks, or the on_exit cleanup
    (which runs before the sandbox checkin) blocks on them.

  Committed writes ride `Sandbox.checkout(_, sandbox: false)`
  connections (sandboxed speculative-insert waits would deadlock the
  window, #241's hazard family), and the file cleans up its own
  committed rows by slug/email/slug-prefix so strands self-heal (#241).
  """

  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Accounts.Organization
  alias FluxVale.Feedback.Comment
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Vote
  alias FluxVale.Identity.User
  alias FluxVale.Repo
  alias FluxVale.Seeds

  require Ash.Query

  @post_slug "seed-race-entry"
  @post_title "Seed race entry"
  @commenter_email "mara@fluxvale.test"
  @comment_body "One reply to race on."

  # How long the harness holds the conflicting row uncommitted. The
  # seeder's find lands within milliseconds of the pass starting, so a
  # one-second hold is ~500x the find's latency: only a machine that
  # stalls the seeder for the full second could flip a site to its
  # find arm (the test stays green — convergence holds either way).
  @release_ms 1_000

  # ── the acceptance: two seeders, one database ─────────────────────

  test "two concurrent seed_feedback! runs converge — one row per identity" do
    cleanup!()

    # seed_feedback! reads the admin before minting; it must exist and
    # be committed before either racer starts.
    committed?(fn -> assert :ok == Seeds.seed_admin!() end)

    parent = self()

    racers =
      for name <- [:a, :b] do
        spawn(fn ->
          conn = Sandbox.checkout(Repo, sandbox: false)
          send(parent, {:ready, name})

          verdict =
            try do
              receive do
                :go -> Seeds.seed_feedback!([race_entry()])
              end

              :ok
            rescue
              error -> {:raised, Exception.message(error)}
            end

          Sandbox.checkin(Repo, conn)
          send(parent, {:done, name, verdict})
        end)
      end

    # Registered before any assertion: a timeout or verdict failure
    # must still sweep, and the kill precedes the sweep inside one
    # callback.
    on_exit(fn ->
      Enum.each(racers, &Process.exit(&1, :kill))
      cleanup!()
    end)

    # Both racers hold real connections before either seeds, so the
    # mint races are genuine, not a race we happen to win
    Enum.each(1..2, fn _round -> assert_receive {:ready, _name}, 5_000 end)
    Enum.each(racers, fn pid -> send(pid, :go) end)

    assert_receive {:done, _first, :ok}, 30_000
    assert_receive {:done, _second, :ok}, 30_000

    assert_one_row_per_identity!()

    # A serial pass after the racing pair: counters converge with the
    # rows (the racers' converge calls can interleave with each other's
    # mints — the documented #471 heal posture heals on the next pass),
    # and no new rows appear. The pass rides a committed connection — a
    # sandboxed write would roll the heal back.
    committed?(fn -> assert :ok == Seeds.seed_feedback!([race_entry()]) end)

    assert_one_row_per_identity!()
  end

  # ── the per-site harness: every loser arm, deterministically ─────

  describe "a mint that loses the race converges on the winner's row" do
    test "post slug" do
      committed_setup()

      holder =
        hold_row!(fn ->
          admin = admin!()

          Post
          |> Ash.Changeset.for_create(:create, %{title: @post_title, description: "x"},
            actor: admin,
            authorize?: false
          )
          |> Ash.Changeset.force_change_attribute(:slug, @post_slug)
          |> Ash.create!(actor: admin, authorize?: false)
        end)

      sweep_after!(holder)

      committed?(fn -> assert :ok == Seeds.seed_feedback!([race_entry()]) end)
      await_hold!()

      assert_one_row_per_identity!()
    end

    test "vote per org" do
      {post, org} =
        committed_setup_returning(fn ->
          admin = admin!()
          post = committed_post!(admin)

          org =
            Organization.create!(%{name: "Demo voters 1", slug: "demo-voters-01"},
              authorize?: false
            )

          {post, org}
        end)

      holder =
        hold_row!(fn -> Ash.Seed.seed!(Vote, %{post_id: post.id, organization_id: org.id}) end)

      sweep_after!(holder)

      committed?(fn -> assert :ok == Seeds.seed_feedback!([race_entry()]) end)
      await_hold!()

      assert_one_row_per_identity!()
    end

    test "comment per (post, author, body)" do
      {post, author} =
        committed_setup_returning(fn ->
          admin = admin!()
          post = committed_post!(admin)
          author = User.create!(@commenter_email, %{}, authorize?: false)

          {post, author}
        end)

      holder =
        hold_row!(fn ->
          Ash.Seed.seed!(Comment, %{
            post_id: post.id,
            author_user_id: author.id,
            body: @comment_body
          })
        end)

      sweep_after!(holder)

      committed?(fn -> assert :ok == Seeds.seed_feedback!([race_entry()]) end)
      await_hold!()

      assert_one_row_per_identity!()
    end

    test "voter org slug" do
      committed_setup()

      holder =
        hold_row!(fn ->
          Organization.create!(%{name: "Demo voters 1", slug: "demo-voters-01"},
            authorize?: false
          )
        end)

      sweep_after!(holder)

      committed?(fn -> assert :ok == Seeds.seed_feedback!([race_entry()]) end)
      await_hold!()

      assert_one_row_per_identity!()
    end

    test "commenter email" do
      committed_setup()

      # Through the REAL create action: the mirror row the table-backed
      # get_by_email resolves through rides the same uncommitted
      # transaction as the user row, so both blind the find and both
      # commit at release — the shape a real race produces.
      holder = hold_row!(fn -> User.create!(@commenter_email, %{}, authorize?: false) end)

      sweep_after!(holder)

      committed?(fn -> assert :ok == Seeds.seed_feedback!([race_entry()]) end)
      await_hold!()

      assert_one_row_per_identity!()
    end
  end

  # ── fixture + helpers ─────────────────────────────────────────────

  # The fixture entry: one post (the derived slug), two votes
  # (demo-voters-01/02), one comment (mara, the rotation's first
  # author). Distinct slug from feedback_seed_test's light entry — the
  # shared test DB must not couple this file's committed rows to
  # another file's sandboxed ones.
  defp race_entry do
    %{
      slug: @post_slug,
      title: @post_title,
      description: "x",
      status: :open,
      votes: 2,
      comments: [@comment_body],
      age_days: 30,
      status_age_days: 0
    }
  end

  # Admin only — the identities the pass mints itself (voter orgs,
  # commenter) are minted by the committed pass below.
  defp committed_setup do
    cleanup!()
    committed?(fn -> assert :ok == Seeds.seed_admin!() end)
  end

  # The same, returning what the caller's harness row needs committed
  # (its identity's neighbours).
  defp committed_setup_returning(fun) do
    committed_setup()
    committed?(fun)
  end

  defp admin! do
    User.get_by_email!("admin@fluxvale.com", authorize?: false)
  end

  # The converged-state invariant, read through the test's sandbox (the
  # pass's own writes are part of the state it converged): one post for
  # the slug, one comment per (post, author, body), one vote per
  # (post, org), counters equal to their rows.
  defp assert_one_row_per_identity! do
    assert post_count!(@post_slug) == 1
    post = post!()

    Comment
    |> Ash.Query.filter(post_id == ^post.id)
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(&{&1.post_id, &1.author_user_id, &1.body})
    |> Enum.each(fn {_triple, n} -> assert n == 1 end)

    assert comment_rows_for!(post.id) == 1

    Vote
    |> Ash.Query.filter(post_id == ^post.id)
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(&{&1.post_id, &1.organization_id})
    |> Enum.each(fn {_pair, n} -> assert n == 1 end)

    assert vote_rows_for!(post.id) == 2

    assert post.vote_count == vote_rows_for!(post.id)
    assert post.comment_count == comment_rows_for!(post.id)
  end

  # Inserts a row carrying a mint site's exact identity on a committed
  # connection and HOLDS it uncommitted: the seeder's find cannot see
  # it (snapshot), the seeder's mint cannot bypass it (the unique index
  # waits on the held insertion), and the release commit turns the wait
  # into the violation. The find-sees-nil, create-collides window of a
  # real two-seeder race, staged deterministically. Raw spawn, NOT
  # Task.async: a task inherits sandbox ownership through $callers and
  # its "transaction" would become a savepoint on the test's sandbox
  # transaction instead of an independent committed one. Returns the
  # holder's pid for sweep_after!/1; returns once the hold is in place.
  defp hold_row!(insert) do
    parent = self()

    holder =
      spawn(fn ->
        conn = Sandbox.checkout(Repo, sandbox: false)

        result =
          try do
            Repo.transaction(fn ->
              winner = insert.()
              send(parent, {:held, winner})

              receive do
                _release -> :ok
              after
                @release_ms -> :ok
              end

              {:ok, winner}
            end)
          rescue
            error -> {:raised, error}
          after
            Sandbox.checkin(Repo, conn)
          end

        send(parent, {:held_done, result})
      end)

    assert_receive {:held, _winner}, 5_000
    holder
  end

  defp await_hold! do
    assert_receive {:held_done, {:ok, _winner}}, 10_000
  end

  # Registers the on_exit sweep for one harness test: the holder goes
  # first — a test body that failed before await_hold!/0 leaves the
  # holder parked on its row, and its transaction holds the locks the
  # sweep needs. Killing it rolls the hold back and frees the sweep.
  defp sweep_after!(holder) do
    on_exit(fn ->
      Process.exit(holder, :kill)
      cleanup!()
    end)
  end

  # The harness post rides a forced slug: DeriveSlug's probe would
  # suffix a mint whose probe runs after any stray committed row, and
  # the held row must carry the exact slug the fixture entry derives.
  defp committed_post!(admin) do
    Post
    |> Ash.Changeset.for_create(:create, %{title: @post_title, description: "x"},
      actor: admin,
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:slug, @post_slug)
    |> Ash.create!(actor: admin, authorize?: false)
  end

  defp post! do
    Post
    |> Ash.Query.filter(slug == ^@post_slug)
    |> Ash.read_one!(authorize?: false)
  end

  defp post_count!(slug) do
    Post
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.count!(authorize?: false)
  end

  defp vote_rows_for!(post_id) do
    Vote
    |> Ash.Query.filter(post_id == ^post_id)
    |> Ash.count!(authorize?: false)
  end

  defp comment_rows_for!(post_id) do
    Comment
    |> Ash.Query.filter(post_id == ^post_id)
    |> Ash.count!(authorize?: false)
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

  # Removes the committed rows — the sandbox never owns them. Children
  # go before their parents, inside one transaction: access_gateways
  # and access_domains RESTRICT their organization FK, instance
  # hostnames RESTRICT their access_domain FK (the instance delete
  # cascades them first), the billing tables are no-action, and the
  # post delete cascades its comments and votes (both post FKs are
  # on_delete :delete). The slug sweep is a prefix match so a stray
  # probe-suffixed post cannot strand (the forced-slug mints make that
  # unreachable today — the belt stays). SQL-selected uuid ids arrive
  # decoded as 16-byte binaries, ready to pass back as uuid[] params.
  defp cleanup! do
    committed?(fn ->
      user_ids =
        uuid_ids(
          Repo.query!("SELECT id FROM users WHERE email = ANY($1::citext[])", [
            ["admin@fluxvale.com", @commenter_email]
          ])
        )

      # orgs: the users' personal orgs (via memberships) plus the demo
      # voter pool the seeds mint ownerless
      org_ids =
        uuid_ids(
          Repo.query!(
            "SELECT organization_id FROM memberships WHERE user_id = ANY($1) UNION SELECT id FROM organizations WHERE slug LIKE 'demo-voters-%'",
            [user_ids]
          )
        )

      Repo.transaction(fn ->
        Repo.query!("DELETE FROM access_gateways WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM instances WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM access_domains WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM billing_topups WHERE organization_id = ANY($1)", [org_ids])

        Repo.query!(
          "DELETE FROM billing_ledger_entries WHERE wallet_id IN (SELECT id FROM billing_wallets WHERE organization_id = ANY($1))",
          [org_ids]
        )

        Repo.query!("DELETE FROM billing_wallets WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM feedback_posts WHERE slug LIKE $1", [@post_slug <> "%"])
        Repo.query!("DELETE FROM memberships WHERE organization_id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM user_emails WHERE user_id = ANY($1)", [user_ids])
        Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [org_ids])
        Repo.query!("DELETE FROM users WHERE id = ANY($1)", [user_ids])
      end)
    end)
  end

  defp uuid_ids(%{rows: rows}) do
    Enum.map(rows, fn [id] -> id end)
  end
end
