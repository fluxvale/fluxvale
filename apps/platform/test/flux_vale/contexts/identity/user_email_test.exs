defmodule FluxVale.Identity.UserEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Repo

  require Ash.Query

  # Preconditions run authorize?: false — there is no actor to authorize
  # while building state (mirrors the seeds; the house rule). The
  # actor-ful calls in the assertions below are the actual test subject.
  #
  # NB: since the create mirror (#285 T3 §5), every action-created user
  # starts with ONE verified primary row for its signup address — the
  # counts below are written against that baseline.
  defp create_user(email, attrs \\ %{}) do
    User.create!(email, attrs, authorize?: false)
  end

  defp add_email(user, address, opts \\ []) do
    UserEmail.add(address, %{user: user},
      actor: Keyword.get(opts, :actor, user),
      authorize?: Keyword.get(opts, :authorize?, true)
    )
  end

  # The create-mirror row: the user's one verified primary at birth.
  defp mirror_row(user) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user.id and is_primary)
    |> Ash.read_one!(authorize?: false)
  end

  # Adds, verifies, and reloads — a verified row straight through
  # actions. Verification rides the internal path (authorize?: false):
  # in production only the auth-code identity operation stamps it.
  defp verified_email(user, address) do
    {:ok, row} = add_email(user, address, authorize?: false)
    {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)
    Ash.get!(UserEmail, row.id, authorize?: false)
  end

  defp count_primaries(user) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user.id and is_primary == true)
    |> Ash.count!(authorize?: false)
  end

  defp count_rows(user) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.count!(authorize?: false)
  end

  defp count_verified(user) do
    UserEmail
    |> Ash.Query.filter(user_id == ^user.id and not is_nil(verified_at))
    |> Ash.count!(authorize?: false)
  end

  describe "add/2" do
    test "creates a pending (unverified, non-primary) row for the actor" do
      user = create_user("owner@emails.fluxvale.test")

      assert {:ok, row} = add_email(user, "side@emails.fluxvale.test")
      assert row.user_id == user.id
      assert row.verified_at == nil
      assert row.is_primary == false
    end

    test "refuses malformed addresses" do
      user = create_user("shape@emails.fluxvale.test")

      assert {:error, %Ash.Error.Invalid{}} =
               add_email(user, "not-an-email", authorize?: false)
    end

    test "enforces global case-insensitive uniqueness (an address, one account)" do
      first = create_user("first@emails.fluxvale.test")
      second = create_user("second@emails.fluxvale.test")

      assert {:ok, _shared} = add_email(first, "shared@emails.fluxvale.test", authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               add_email(second, "SHARED@emails.fluxvale.test", authorize?: false)
    end

    test "frees the address once removed — another user can claim it" do
      first = create_user("freer@emails.fluxvale.test")
      second = create_user("claimer@emails.fluxvale.test")

      # a second verified row keeps the only-verified guard happy
      verified_email(first, "anchor@emails.fluxvale.test")
      recycled = verified_email(first, "recycled@emails.fluxvale.test")

      assert UserEmail.remove(recycled, actor: first, authorize?: true) == :ok

      assert {:ok, _claimed} =
               add_email(second, "recycled@emails.fluxvale.test", actor: second, authorize?: true)
    end

    test "caps a user at #{UserEmail.max_emails_per_user()} addresses" do
      user = create_user("capped@emails.fluxvale.test")
      cap = UserEmail.max_emails_per_user()

      # the create mirror counts against the cap (T3 §5)
      for n <- 1..(cap - 1) do
        assert {:ok, _added} =
                 add_email(user, "cap#{n}@emails.fluxvale.test", authorize?: false)
      end

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               add_email(user, "one-too-many@emails.fluxvale.test", authorize?: false)

      assert message =~ "too many email addresses"
    end

    test "the cap holds on the bulk path — a whole over-cap batch fails" do
      user = create_user("bulk-capped@emails.fluxvale.test")
      cap = UserEmail.max_emails_per_user()

      inputs =
        for n <- 1..(cap + 3) do
          %{address: "bulk#{n}@emails.fluxvale.test", user: user}
        end

      # The trigger is DEFERRABLE INITIALLY DEFERRED — inside a sandboxed
      # test (one big transaction) it would only fire at test end, so flip
      # it to IMMEDIATE: the checks then run at each statement's end, the
      # same moment a production commit would run them.
      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

      # authorize?: false — the cap is a data invariant, not a policy
      # question (same posture as the single-row cap test).
      result = Ash.bulk_create(inputs, UserEmail, :add, authorize?: false, return_errors?: true)

      refute match?({:ok, %Ash.BulkResult{status: :success}}, result)

      # whole-batch rollback: not a partial insert of cap-3 stragglers —
      # and the create mirror is untouched by the failed batch
      assert count_rows(user) == 1
    end

    test "the cap holds when the caller disables bulk transactions" do
      user = create_user("no-tx-bulk@emails.fluxvale.test")
      cap = UserEmail.max_emails_per_user()

      inputs =
        for n <- 1..(cap + 3) do
          %{address: "notx#{n}@emails.fluxvale.test", user: user}
        end

      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

      # authorize?: false — data invariant, as above.
      result =
        Ash.bulk_create(inputs, UserEmail, :add,
          authorize?: false,
          transaction: false,
          return_errors?: true
        )

      refute match?({:ok, %Ash.BulkResult{status: :success}}, result)
      assert count_rows(user) <= cap
    end

    test "the cap holds across batch splits (batch_size: 2)" do
      user = create_user("batched-bulk@emails.fluxvale.test")
      cap = UserEmail.max_emails_per_user()

      inputs =
        for n <- 1..(cap + 3) do
          %{address: "split#{n}@emails.fluxvale.test", user: user}
        end

      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

      result =
        Ash.bulk_create(inputs, UserEmail, :add,
          authorize?: false,
          batch_size: 2,
          return_errors?: true
        )

      refute match?({:ok, %Ash.BulkResult{status: :success}}, result)
      assert count_rows(user) <= cap
    end

    test "the cap is a data-layer arbiter — even non-Ash writes cannot exceed it" do
      user = create_user("raw-sql@emails.fluxvale.test")
      now = DateTime.utc_now()

      rows =
        for n <- 1..6 do
          %{
            id: Ash.UUIDv7.bingenerate(),
            user_id: Ecto.UUID.dump!(user.id),
            address: "raw#{n}@emails.fluxvale.test",
            is_primary: false,
            created_at: now,
            updated_at: now
          }
        end

      # Sanctioned bypass: this test deliberately writes around actions
      # (raw insert_all, no Ash type layer — hence bingenerate + the
      # dumped uuid) to prove the cap lives in the data layer, not in
      # changeset hooks. The savepoint keeps the test's own transaction
      # alive after the violation.
      assert_raise(Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
          Repo.insert_all("user_emails", rows)
        end)
      end)

      # only the create mirror remains
      assert count_rows(user) == 1
    end

    test "the cap holds on the upsert path — upserts are updates, not inserts" do
      victim = create_user("upsert-victim@emails.fluxvale.test")
      donor = create_user("upsert-donor@emails.fluxvale.test")
      cap = UserEmail.max_emails_per_user()

      # donor owns cap addresses (mirror + cap-1 adds); victim starts 2
      # under the cap (mirror + 2 adds)
      addresses =
        for n <- 1..(cap - 1) do
          address = "ups#{n}@emails.fluxvale.test"
          {:ok, _donor_row} = add_email(donor, address, authorize?: false)
          address
        end

      for n <- 1..2 do
        {:ok, _victim_row} =
          add_email(victim, "victim#{n}@emails.fluxvale.test", authorize?: false)
      end

      inputs = for a <- addresses, do: %{address: a, user: victim}

      Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

      # authorize?: false — data invariant, as above.
      result =
        Ash.bulk_create(inputs, UserEmail, :add,
          authorize?: false,
          upsert?: true,
          upsert_identity: :unique_address,
          upsert_fields: [:user_id],
          return_errors?: true
        )

      refute match?({:ok, %Ash.BulkResult{status: :success}}, result)
      assert count_rows(victim) <= cap
    end

    test "the cap holds when rows are moved between accounts (UPDATE of user_id)" do
      donor = create_user("mover-donor@emails.fluxvale.test")
      victim = create_user("mover-victim@emails.fluxvale.test")
      cap = UserEmail.max_emails_per_user()

      # the mirror + cap-1 adds = a donor at the cap
      for n <- 1..(cap - 1) do
        {:ok, _donor_row} = add_email(donor, "mov#{n}@emails.fluxvale.test", authorize?: false)
      end

      {:ok, _victim_row} = add_email(victim, "mov-victim@emails.fluxvale.test", authorize?: false)

      # Sanctioned bypass: a raw user_id move is exactly the write the
      # UPDATE trigger exists for — no Ash action can express it.
      assert_raise(Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

          donor_id = Ecto.UUID.dump!(donor.id)
          victim_id = Ecto.UUID.dump!(victim.id)

          move =
            from(e in "user_emails",
              where: e.user_id == ^donor_id,
              update: [set: [user_id: ^victim_id]]
            )

          Repo.update_all(move, [])
        end)
      end)

      # the victim keeps its own mirror + add — the refused move changed nothing
      assert count_rows(victim) == 2
    end
  end

  describe "mark_verified/1" do
    test "stamps verified_at (the internal path — verification is proven by the auth code, not the actor)" do
      user = create_user("verifier@emails.fluxvale.test")
      {:ok, row} = add_email(user, "pending@emails.fluxvale.test", authorize?: false)
      assert row.verified_at == nil

      assert {:ok, verified} = UserEmail.mark_verified(row, authorize?: false)
      assert %DateTime{} = verified.verified_at
      assert DateTime.compare(verified.verified_at, DateTime.utc_now()) != :gt
    end

    test "refuses an owner stamping their own address — verification needs a proven code" do
      user = create_user("self-stamper@emails.fluxvale.test")
      {:ok, row} = add_email(user, "unproven@emails.fluxvale.test", authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               UserEmail.mark_verified(row, actor: user, authorize?: true)
    end
  end

  describe "set_primary/1" do
    test "flips the old primary off — exactly one primary remains" do
      user = create_user("switcher@emails.fluxvale.test")
      first = verified_email(user, "first@emails.fluxvale.test")
      verified_email(user, "second@emails.fluxvale.test")

      assert {:ok, _promoted} = UserEmail.set_primary(first, actor: user, authorize?: true)
      assert count_primaries(user) == 1

      only =
        UserEmail
        |> Ash.Query.filter(user_id == ^user.id and is_primary == true)
        |> Ash.read!(authorize?: false)
        |> Enum.at(0)

      assert only.address == first.address
    end

    test "refuses a pending row" do
      user = create_user("impatient@emails.fluxvale.test")
      {:ok, pending} = add_email(user, "not-yet@emails.fluxvale.test", authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               UserEmail.set_primary(pending, actor: user, authorize?: true)

      assert message =~ "must be verified"
    end

    test "judges fresh state, not the caller's struct — a forged verified_at cannot promote a pending row" do
      user = create_user("forger@emails.fluxvale.test")
      {:ok, pending} = add_email(user, "forged@emails.fluxvale.test", authorize?: false)
      forged = Map.put(pending, :verified_at, DateTime.utc_now())

      assert {:error, %Ash.Error.Invalid{}} =
               UserEmail.set_primary(forged, actor: user, authorize?: true)

      still =
        UserEmail
        |> Ash.Query.filter(address == ^Ash.CiString.value(pending.address))
        |> Ash.read_one!(authorize?: false)

      refute still.is_primary
    end

    test "a set_primary on an already-deleted row is a clean error, not a raise" do
      user = create_user("gone-promoter@emails.fluxvale.test")
      admin = create_user("gone-promoter-admin@emails.fluxvale.test", %{platform_role: :admin})
      {:ok, pending} = add_email(user, "vanished@emails.fluxvale.test", authorize?: false)

      assert UserEmail.remove(pending, actor: admin, authorize?: true) == :ok

      assert {:error, %Ash.Error.Invalid{}} =
               UserEmail.set_primary(pending, actor: admin, authorize?: true)
    end
  end

  describe "remove/1" do
    test "refuses the primary address" do
      user = create_user("keeper@emails.fluxvale.test")
      verified_email(user, "primary@emails.fluxvale.test")
      row = verified_email(user, "other@emails.fluxvale.test")
      {:ok, _promoted} = UserEmail.set_primary(row, actor: user, authorize?: true)

      rows = Ash.read!(UserEmail, authorize?: false)

      primary =
        Enum.find(rows, &(&1.user_id == user.id and &1.is_primary))

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               UserEmail.remove(primary, actor: user, authorize?: true)

      assert message =~ "primary"
    end

    test "refuses removing the create mirror — it is frozen into users.email (#285 T3 §5)" do
      # The mirror is the account's only verified address before any
      # switch; the frozen clause is its accurate refusal (the
      # only-verified branch fires on drifted data — see the
      # guard-concurrency test).
      user = create_user("sole@emails.fluxvale.test")
      primary = mirror_row(user)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               UserEmail.remove(primary, actor: user, authorize?: true)

      assert message =~ "frozen"
      assert count_verified(user) == 1
    end

    test "refuses the signup address — frozen into users.email even after a switch (#285 T3)" do
      # Sign-in resolves through this table; if the frozen mirror's row
      # went away, the address would be unresolvable AND unprovisionable
      # (the users unique-email index still holds it).
      user = create_user("frozen@emails.fluxvale.test")
      second = verified_email(user, "switched@emails.fluxvale.test")
      {:ok, _promoted} = UserEmail.set_primary(second, actor: user, authorize?: true)

      old =
        UserEmail
        |> Ash.Query.filter(address == ^user.email)
        |> Ash.read_one!(authorize?: false)

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               UserEmail.remove(old, actor: user, authorize?: true)

      assert message =~ "frozen"
    end

    test "allows removing a pending row while a verified one remains" do
      user = create_user("tidier@emails.fluxvale.test")
      verified_email(user, "stay@emails.fluxvale.test")
      {:ok, pending} = add_email(user, "churn@emails.fluxvale.test", authorize?: false)

      assert UserEmail.remove(pending, actor: user, authorize?: true) == :ok
    end

    test "allows removing a non-primary verified row when another verified remains" do
      user = create_user("pruner@emails.fluxvale.test")
      verified_email(user, "anchor@emails.fluxvale.test")
      spare = verified_email(user, "spare@emails.fluxvale.test")

      assert UserEmail.remove(spare, actor: user, authorize?: true) == :ok
    end

    test "allows removing the only pending row (nothing verified is lost)" do
      user = create_user("typo@emails.fluxvale.test")
      {:ok, pending} = add_email(user, "typo-claim@emails.fluxvale.test", authorize?: false)

      assert UserEmail.remove(pending, actor: user, authorize?: true) == :ok
    end

    test "judges fresh state, not the caller's struct — a stale snapshot of the now-primary row is refused" do
      user = create_user("stale@emails.fluxvale.test")
      verified_email(user, "stale-a@emails.fluxvale.test")
      promoted = verified_email(user, "stale-b@emails.fluxvale.test")

      # snapshot taken BEFORE the promotion — a real call, no forgery
      {:ok, stale} = Ash.get(UserEmail, promoted.id, authorize?: false)
      {:ok, _promoted} = UserEmail.set_primary(promoted, actor: user, authorize?: true)
      refute stale.is_primary

      assert {:error, %Ash.Error.Invalid{}} =
               UserEmail.remove(stale, actor: user, authorize?: true)

      # the primary survived: exactly one remains
      assert count_primaries(user) == 1
    end

    test "a second remove with the same (now-deleted) struct is a clean error, not a raise" do
      user = create_user("twice@emails.fluxvale.test")
      admin = create_user("twice-admin@emails.fluxvale.test", %{platform_role: :admin})
      {:ok, pending} = add_email(user, "once@emails.fluxvale.test", authorize?: false)

      assert UserEmail.remove(pending, actor: admin, authorize?: true) == :ok

      # admin path: no policy filter short-circuits, so the guard itself
      # refuses the vanished row. (An owner actor gets Forbidden from the
      # policy filter first — also clean, never a raise.)
      assert {:error, %Ash.Error.Invalid{}} =
               UserEmail.remove(pending, actor: admin, authorize?: true)
    end

    test "a decoy user_id cannot dodge the per-user lock — the last verified row always refuses" do
      owner = create_user("decoyed@emails.fluxvale.test")
      decoy = create_user("decoy@emails.fluxvale.test")
      first = verified_email(owner, "last-a@emails.fluxvale.test")
      second = verified_email(owner, "last-b@emails.fluxvale.test")
      mirror = mirror_row(owner)
      admin = create_user("decoy-admin@emails.fluxvale.test", %{platform_role: :admin})

      # forged structs point the lock target at an unrelated account;
      # the guard must lock the FRESH row's user instead
      forged_first = Map.put(first, :user_id, decoy.id)
      assert UserEmail.remove(forged_first, actor: admin, authorize?: true) == :ok

      forged_second = Map.put(second, :user_id, decoy.id)
      assert UserEmail.remove(forged_second, actor: admin, authorize?: true) == :ok

      # only the mirror is left — the last verified. Forging its user_id
      # still hits the guard, which reads fresh state.
      forged_mirror = Map.put(mirror, :user_id, decoy.id)

      assert {:error, %Ash.Error.Invalid{}} =
               UserEmail.remove(forged_mirror, actor: admin, authorize?: true)

      assert count_verified(owner) == 1
    end
  end

  describe "the partial unique index (at most one primary per user)" do
    test "rejects a forced second primary at the database" do
      user = create_user("indexed@emails.fluxvale.test")
      row = verified_email(user, "real@emails.fluxvale.test")
      {:ok, _promoted} = UserEmail.set_primary(row, actor: user, authorize?: true)

      # Ash.Seed! is the sanctioned bypass here: no action can produce two
      # primaries (set_primary demotes siblings first), so this state only
      # exists to prove the index arbitrates even against non-Ash writes.
      assert_raise(Ash.Error.Invalid, ~r/has already been taken/, fn ->
        Ash.Seed.seed!(UserEmail, %{
          user_id: user.id,
          address: "forced@emails.fluxvale.test",
          is_primary: true,
          verified_at: DateTime.utc_now()
        })
      end)

      assert count_primaries(user) == 1
    end
  end

  describe "the cap trigger (data-layer arbiter)" do
    test "the SQL cap cannot drift from the resource constant" do
      # The twin tie: the trigger's hardcoded cap and
      # UserEmail.max_emails_per_user/0 must move together (the DSL
      # cannot parametrize raw SQL, and ash.codegen --check cannot see
      # the trigger) — so read the LIVE function definition and pin it
      # to the constant. Bumping one without the other fails here.
      %{rows: [[definition]]} =
        Repo.query!("SELECT pg_get_functiondef('fluxvale_user_email_cap'::regproc)")

      assert definition =~ ~r/> #{UserEmail.max_emails_per_user()}/
    end
  end

  describe "supersede_pending (the pending-only invariant lives on the action — review round 2, P2)" do
    test "the owner cannot destroy their own verified primary through it — rows intact" do
      user = create_user("supersede-owner@emails.fluxvale.test")
      row = mirror_row(user)

      # the action's is_nil(verified_at) filter refuses the delete at
      # the resource, regardless of caller — the destroy policy would
      # grant the owner, and RemoveGuard is not on this action
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Ash.destroy(row, action: :supersede_pending, actor: user, authorize?: true)

      assert count_rows(user) == 1
      assert mirror_row(user).is_primary
      refute is_nil(mirror_row(user).verified_at)
    end

    test "a platform admin cannot destroy another user's verified mirror through it — rows intact" do
      owner = create_user("supersede-victim@emails.fluxvale.test")

      admin =
        create_user("supersede-admin@emails.fluxvale.test", %{platform_role: :admin})

      row = mirror_row(owner)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Ash.destroy(row, action: :supersede_pending, actor: admin, authorize?: true)

      assert count_rows(owner) == 1
      refute is_nil(mirror_row(owner).verified_at)
    end

    test "the internal seam still removes pending rows" do
      user = create_user("supersede-internal@emails.fluxvale.test")
      address = "supersede-claim-#{System.unique_integer()}@emails.fluxvale.test"
      {:ok, _claim} = add_email(user, address, authorize?: false)

      assert :ok = UserEmail.supersede_pending_claims(address)

      # only the create mirror remains — the claim is gone
      assert count_rows(user) == 1
    end
  end

  describe "policies" do
    test "a user cannot add to, or touch, another user's rows" do
      owner = create_user("mine-owner@emails.fluxvale.test")
      stranger = create_user("mine-stranger@emails.fluxvale.test")
      row = verified_email(owner, "theirs@emails.fluxvale.test")

      assert {:error, %Ash.Error.Forbidden{}} =
               add_email(owner, "hijack@emails.fluxvale.test", actor: stranger)

      assert {:error, %Ash.Error.Forbidden{}} =
               UserEmail.mark_verified(row, actor: stranger, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               UserEmail.set_primary(row, actor: stranger, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               UserEmail.remove(row, actor: stranger, authorize?: true)
    end

    test "a user cannot read another user's rows — :mine only ever sees their own" do
      owner = create_user("read-owner@emails.fluxvale.test")
      stranger = create_user("read-stranger@emails.fluxvale.test")
      row = verified_email(owner, "private@emails.fluxvale.test")

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.get(UserEmail, row.id, actor: stranger, authorize?: true)

      # the stranger sees only their own rows (their create mirror)
      assert {:ok, mine} = UserEmail.mine(actor: stranger)
      assert Enum.map(mine, & &1.user_id) == [stranger.id]

      # the owner sees the private row among theirs
      assert {:ok, mine} = UserEmail.mine(actor: owner)
      assert row.id in Enum.map(mine, & &1.id)
    end

    test "a platform admin manages any row" do
      owner = create_user("admin-owned@emails.fluxvale.test")
      row = verified_email(owner, "managed@emails.fluxvale.test")

      admin =
        create_user("email-admin@emails.fluxvale.test", %{platform_role: :admin})

      assert {:ok, _restamped} = UserEmail.mark_verified(row, actor: admin, authorize?: true)

      assert {:ok, _all} = Ash.read(UserEmail, actor: admin, authorize?: true)
    end

    test "unset_primary is internal — an owner cannot demote their only primary" do
      user = create_user("demoter@emails.fluxvale.test")
      row = verified_email(user, "anchor@emails.fluxvale.test")
      {:ok, _promoted} = UserEmail.set_primary(row, actor: user, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(row, %{}, action: :unset_primary, actor: user, authorize?: true)

      assert count_primaries(user) == 1
    end

    test "the AshAuthentication interaction context grants nothing here — no strategy touches this resource" do
      user = create_user("interaction@emails.fluxvale.test")
      row = verified_email(user, "unbypassed@emails.fluxvale.test")
      context = %{private: %{ash_authentication?: true}}

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(row, %{},
                 action: :unset_primary,
                 actor: user,
                 context: context,
                 authorize?: true
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(UserEmail, context: context, authorize?: true)
    end

    test "calls without an actor are forbidden" do
      owner = create_user("anon-owner@emails.fluxvale.test")
      row = verified_email(owner, "secret@emails.fluxvale.test")

      assert {:error, %Ash.Error.Forbidden{}} =
               UserEmail.mark_verified(row, authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.read(UserEmail, authorize?: true)
    end
  end
end
