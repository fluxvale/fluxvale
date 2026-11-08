defmodule FluxVale.Seeds.AdminSeedTest do
  @moduledoc """
  The promotable seed (`FluxVale.Seeds.seed/0` — dev `mix setup` AND the
  release's `bin/seed` run this path) against a sandboxed DB, so drift
  between helper and resources fails here (#98). Covers the admin-org
  heal (#165) — pre-#119 accounts never got a personal org.
  """

  # async: false — the seed address (admin@fluxvale.com) is inserted by
  # every test in this file; concurrent sandbox transactions acquire the
  # users/user_emails index keys in OPPOSITE orders (claim-then-create vs
  # create-then-mirror), which deadlocks (PG 40P01). Serializing this
  # file removes the densest partner pool; the pending-claim scenario
  # additionally runs on a dedicated owner with a retry for the
  # cross-file stragglers (see run_claim_scenario!/0).
  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FluxVale.Accounts
  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing
  alias FluxVale.Billing.LedgerEntry
  alias FluxVale.Catalog.Category
  alias FluxVale.Feedback.Post
  alias FluxVale.Feedback.Tag
  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Repo
  alias FluxVale.Seeds
  alias FluxVale.TestSupport.AccountsFixtures

  require Ash.Query

  describe "seed_admin!/0" do
    test "creates the bootstrap platform admin" do
      :ok = Seeds.seed_admin!()

      assert %{platform_role: :admin} =
               User.get_by_email!("admin@fluxvale.com", authorize?: false)
    end

    test "idempotent — a second run keeps one admin row" do
      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin!()

      assert {:ok, %User{}} = User.get_by_address("admin@fluxvale.com", authorize?: false)
    end

    test "raises on an existing non-admin occupant of the seed email" do
      User.create!("admin@fluxvale.com", %{platform_role: :user}, authorize?: false)

      assert_raise RuntimeError, ~r/non-admin role/, fn ->
        Seeds.seed_admin!()
      end

      # The squatter is untouched — promotion is an operator decision
      assert {:ok, %{platform_role: :user}} =
               User.get_by_address("admin@fluxvale.com", authorize?: false)
    end

    # #285 review P2-2: a pending claim on the seed address used to
    # collide the create (unique_address) and fail EVERY deploy
    # (ADR-0033's init container boots NotReady). The seed supersedes it.
    #
    # The scenario runs in a DEDICATED sandbox transaction (a spawned
    # process on a fresh owner), not this test's: several other suite
    # tests insert the same fixed address, and a claim held in this
    # test's own transaction would pin that index key until test end —
    # cross-test insert cycles then deadlock (PG 40P01) with no possible
    # in-transaction retry. A dedicated owner releases everything when
    # the attempt aborts, so the retry is clean; a third failure is a
    # real bug and propagates.
    test "supersedes a pending claim on the seed address — the deploy-seed arm" do
      %{admin: admin, rows: rows} = run_claim_scenario!()

      assert %{platform_role: :admin} = admin

      # the claim is gone — exactly one row for the address, the admin's
      # verified-primary mirror
      assert [%{user_id: owner_id, verified_at: verified, is_primary: true}] = rows
      assert owner_id == admin.id
      refute is_nil(verified)
    end

    @retry_attempts 3

    defp run_claim_scenario! do
      retry_deadlock(@retry_attempts, fn ->
        # start_owner! allows its caller; this test process is already
        # allowed by DataCase's owner, so the owner is started from a
        # throwaway task process instead
        owner_task = Task.async(fn -> Sandbox.start_owner!(Repo) end)
        owner = Task.await(owner_task)

        parent = self()

        child =
          spawn(fn ->
            receive do
              :go -> send(parent, {:claim_scenario, scenario_result()})
            end
          end)

        Sandbox.allow(Repo, owner, child)
        send(child, :go)

        try do
          receive do
            {:claim_scenario, {:ok, data}} -> data
            {:claim_scenario, {:raised, error}} -> raise error
          after
            30_000 -> raise "claim scenario child did not report back"
          end
        after
          # releases the attempt's keys even (especially) on a deadlock
          Sandbox.stop_owner(owner)
        end
      end)
    end

    # The child reports raises as data — an unhandled crash there would
    # skip the retry entirely.
    defp scenario_result do
      {:ok, claim_scenario()}
    rescue
      error -> {:raised, error}
    end

    defp claim_scenario do
      claimant =
        User.create!("seed-claimant-#{System.unique_integer()}@fluxvale.test", %{},
          authorize?: false
        )

      {:ok, _claim} = UserEmail.add("admin@fluxvale.com", %{user: claimant}, authorize?: false)

      :ok = Seeds.seed_admin!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)

      rows = seed_address_rows()

      %{admin: %{id: admin.id, platform_role: admin.platform_role}, rows: rows}
    end

    # See run_claim_scenario!/0: a fresh attempt is deterministic — the
    # aborted attempt's rollback freed the keys it held and unblocked the
    # test it deadlocked with.
    defp retry_deadlock(attempts, fun) when attempts > 1 do
      fun.()
    rescue
      error in RuntimeError ->
        if Regex.match?(~r/could not be created/, error.message) do
          retry_deadlock(attempts - 1, fun)
        else
          reraise error, __STACKTRACE__
        end
    end

    defp retry_deadlock(_attempts_left, fun), do: fun.()

    test "an outstanding invitation on the seed address fails loudly — no second account" do
      # #287: the mirror-era heal arms died with the column. The one
      # sequential collision shape left is an INVITED reservation on the
      # seed address — bootstrap names it and refuses to fork a second
      # account; the operator retires or re-points the invitation.
      assert {:ok, invited, _raw} =
               Identity.invite_user(
                 nil,
                 "admin@fluxvale.com",
                 fn _address, _url ->
                   {:ok, :suppressed}
                 end,
                 authorize?: false
               )

      assert_raise RuntimeError, ~r/outstanding invitation/, fn ->
        Seeds.seed_admin!()
      end

      # nothing was invented: the reservation still belongs to the invite
      assert {:ok, occupant} = User.get_by_address("admin@fluxvale.com", authorize?: false)
      assert occupant.id == invited.id
      assert [%{user_id: owner_id, verified_at: nil}] = seed_address_rows()
      assert owner_id == invited.id
    end

    test "a withdrawn invitation on the seed address still raises — the reservation keeps the address" do
      # Retirement does not free the address (#287's window ruling: the
      # reservation lives from invite to acceptance) — withdrawal keeps
      # it, so the seed still collides and still names the occupant.
      assert {:ok, invited, _raw} =
               Identity.invite_user(
                 nil,
                 "admin@fluxvale.com",
                 fn _address, _url ->
                   {:ok, :suppressed}
                 end,
                 authorize?: false
               )

      invited
      |> Ash.Changeset.for_update(:withdraw_invite, %{})
      |> Ash.update!(authorize?: false)

      assert_raise RuntimeError, ~r/outstanding invitation/, fn ->
        Seeds.seed_admin!()
      end
    end

    defp seed_address_rows, do: rows_for("admin@fluxvale.com")

    defp rows_for(address) do
      UserEmail
      |> Ash.Query.filter(address == ^address)
      |> Ash.read!(authorize?: false)
    end
  end

  describe "seed_admin_org!/0" do
    # Ash.Seed.seed! — pre-#119 admins have no org and the User create
    # action now always provisions one (state actions can't produce, the
    # documented seed! exception). attach_primary_email! adds the row
    # the create path would have — without it the table-backed identity
    # (#285 T3) cannot see the admin.
    defp seed_pre119_admin! do
      admin =
        Ash.Seed.seed!(User, %{
          platform_role: :admin,
          username: "admin-2"
        })

      AccountsFixtures.attach_primary_email!(admin, "admin@fluxvale.com")
      admin
    end

    test "heals a pre-#119 admin — exactly one personal org, owner membership" do
      seed_pre119_admin!()

      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin_org!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      assert org_count(admin.id) == 1

      [membership] = memberships(personal_org!(admin.id).id)
      assert membership.role == :owner
      assert membership.user_id == admin.id
    end

    test "idempotent — a second run adds no org and no second ledger entry" do
      seed_pre119_admin!()

      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin_org!()
      :ok = Seeds.seed_admin_org!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      org = personal_org!(admin.id)

      assert org_count(admin.id) == 1

      {:ok, wallet} = Billing.ensure_wallet(org)
      assert {:ok, 300} = Billing.balance(wallet, authorize?: false)
      assert length(welcome_entries(wallet)) == 1
    end

    test "an admin that already has an org is untouched" do
      # seed_admin! creates through the User create action, whose JIT
      # change already provisions the org — seed_admin_org! must no-op.
      :ok = Seeds.seed_admin!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      org_before = personal_org!(admin.id)

      :ok = Seeds.seed_admin_org!()

      assert personal_org!(admin.id).id == org_before.id
      assert org_count(admin.id) == 1

      {:ok, wallet} = Billing.ensure_wallet(org_before)
      assert length(welcome_entries(wallet)) == 1
    end

    test "the welcome grant is 300 cents with reason :welcome" do
      seed_pre119_admin!()

      :ok = Seeds.seed_admin!()
      :ok = Seeds.seed_admin_org!()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)
      org = personal_org!(admin.id)
      {:ok, wallet} = Billing.ensure_wallet(org)

      [entry] = welcome_entries(wallet)
      assert entry.type == :credit
      assert entry.amount == 300
      assert entry.reason == :welcome
    end

    defp personal_org!(user_id) do
      {:ok, org} = Accounts.personal_org_for_user(user_id, authorize?: false)
      org
    end

    defp org_count(user_id) do
      Organization
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(memberships.user_id == ^user_id and memberships.role == :owner)
      |> Ash.count!(authorize?: false)
    end

    defp memberships(org_id) do
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(organization_id == ^org_id)
      |> Ash.read!(authorize?: false)
    end

    # The demo-flag tests' restore arm: put back what was there, delete
    # when the runtime had nothing (the test env's default).
    defp restore_demo_flag(nil), do: Application.delete_env(:flux_vale, :seed_demo_content)
    defp restore_demo_flag(value), do: Application.put_env(:flux_vale, :seed_demo_content, value)

    defp welcome_entries(wallet) do
      LedgerEntry
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :welcome)
      |> Ash.read!(authorize?: false)
    end
  end

  describe "seed/0" do
    test "runs admin + catalog — the promotable path, no local-cluster row" do
      :ok = Seeds.seed()

      assert User.get_by_email!("admin@fluxvale.com", authorize?: false)
      # Catalog converged (#70's machinery; Forgejo + Kavita ship in the
      # YAML). Asserted by slug, not row count — the catalog grows.
      assert {:ok, _forgejo} = Category.get_by_slug("developer-tools", authorize?: false)

      assert {:ok, _kavita} = Category.get_by_slug("media", authorize?: false)
    end

    test "the demo-board gate is closed by default (prod posture: honestly empty)" do
      # Global app env — the stub_build_sha posture: flip, restore on
      # exit. async: false keeps the window file-local.
      original = Application.get_env(:flux_vale, :seed_demo_content)
      Application.delete_env(:flux_vale, :seed_demo_content)

      on_exit(fn -> restore_demo_flag(original) end)

      :ok = Seeds.seed()

      assert 0 ==
               Post
               |> Ash.Query.filter(true)
               |> Ash.count!(authorize?: false)

      # The gate reading (T10): the vocabulary is PROMOTABLE seed
      # content, not demo content — the demo gate guards fabricated
      # activity (posts and their votes), while a tag row claims nothing
      # happened, and the board renders only tags in use. So the
      # promotable path arms the vocabulary even with the gate closed.
      slugs =
        Tag
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.slug)

      assert "platform" in slugs
      assert "app-request" in slugs
      # And the catalog's apps joined it (the catalog seeded above).
      assert "forgejo" in slugs
      assert "kavita" in slugs
      assert "pocket-id" in slugs
    end

    test "an opted-in runtime seeds the demo board content" do
      original = Application.get_env(:flux_vale, :seed_demo_content)
      Application.put_env(:flux_vale, :seed_demo_content, true)

      on_exit(fn -> restore_demo_flag(original) end)

      :ok = Seeds.seed()

      assert {:ok, _post} =
               Post
               |> Ash.Query.filter(slug == "suspend-an-instance-from-the-cli")
               |> Ash.read_one(authorize?: false)

      # The demo gate's pairings ride the same arm end-to-end (T10): the
      # vocabulary seeded on the promotable path above, and the gated
      # post carries its tag through seed/0 itself.
      tagged =
        Post
        |> Ash.Query.filter(slug == "kavita-continue-reading-sync-across-devices")
        |> Ash.read_one!(authorize?: false)
        |> Ash.load!(:tags, authorize?: false)

      assert Enum.map(tagged.tags, & &1.slug) == ["kavita"]
    end

    test "heals a pre-#119 admin through the promotable path" do
      # Delegation guard: the heal rides seed/0 itself — dropping
      # seed_admin_org!/0 from it must fail here, not in prod bring-up.
      seed_pre119_admin!()

      :ok = Seeds.seed()

      admin = User.get_by_email!("admin@fluxvale.com", authorize?: false)

      assert 1 ==
               Organization
               |> Ash.Query.for_read(:read, %{})
               |> Ash.Query.filter(
                 memberships.user_id == ^admin.id and memberships.role == :owner
               )
               |> Ash.count!(authorize?: false)

      {:ok, org} = Accounts.personal_org_for_user(admin.id, authorize?: false)
      {:ok, wallet} = Billing.ensure_wallet(org)

      welcome =
        LedgerEntry
        |> Ash.Query.for_read(:read, %{})
        |> Ash.Query.filter(wallet_id == ^wallet.id and reason == :welcome)
        |> Ash.read!(authorize?: false)

      assert length(welcome) == 1
    end
  end
end
