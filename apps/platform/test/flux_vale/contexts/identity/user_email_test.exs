defmodule FluxVale.Identity.UserEmailTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail

  require Ash.Query

  # Preconditions run authorize?: false — there is no actor to authorize
  # while building state (mirrors the seeds; the house rule). The
  # actor-ful calls in the assertions below are the actual test subject.
  defp create_user(email, attrs \\ %{}) do
    User.create!(email, attrs, authorize?: false)
  end

  defp add_email(user, address, opts \\ []) do
    UserEmail.add(address, %{user: user},
      actor: Keyword.get(opts, :actor, user),
      authorize?: Keyword.get(opts, :authorize?, true)
    )
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

      for n <- 1..cap do
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

      # authorize?: false — the cap is a data invariant, not a policy
      # question (same posture as the single-row cap test).
      result = Ash.bulk_create(inputs, UserEmail, :add, authorize?: false, return_errors?: true)

      refute match?({:ok, %Ash.BulkResult{status: :success}}, result)

      # whole-batch rollback: not a partial insert of cap-3 stragglers
      assert count_rows(user) == 0
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

    test "refuses the user's only verified address (even non-primary)" do
      user = create_user("sole@emails.fluxvale.test")
      row = verified_email(user, "only@emails.fluxvale.test")
      refute row.is_primary

      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               UserEmail.remove(row, actor: user, authorize?: true)

      assert message =~ "only verified"
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

    test "allows removing the only row when it is still pending (nothing verified is lost)" do
      user = create_user("typo@emails.fluxvale.test")
      {:ok, pending} = add_email(user, "typo@emails.fluxvale.test", authorize?: false)

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

      assert {:ok, mine} = UserEmail.mine(actor: stranger)
      assert mine == []

      assert {:ok, mine} = UserEmail.mine(actor: owner)
      assert Enum.map(mine, & &1.id) == [row.id]
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
