defmodule FluxVale.Identity.UserTest do
  @moduledoc false

  # Not async: this file's exhaustion/degenerate tests speculate on the
  # same users_unique_username_index keys ("user"…"user-100") that
  # provision_personal_org_test's degenerate fixtures derive — concurrent
  # sandbox transactions deadlock there (40P01: the pair alone 7/10,
  # serialized 0/8). Non-async cases run after all async ones, so the
  # files never overlap.
  use FluxVale.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias FluxVale.Checks.CallOutsideMachineApi
  alias FluxVale.Identity.User
  alias FluxVale.Identity.User.DeriveUsername
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Repo

  require Ash.Query

  # The first user is bootstrapped without authorization — there is no actor
  # to authorize before an admin exists (mirrors priv/repo/seeds.exs).
  defp bootstrap_admin(email) do
    case User.get_by_email(email, authorize?: false) do
      {:ok, existing} -> existing
      {:error, _not_found} -> User.create!(email, %{platform_role: :admin}, authorize?: false)
    end
  end

  describe "create/1" do
    test "the #287 contract, by schema reflection: no email column, username NOT NULL" do
      # The DoD assert: the legacy column is GONE and the handle is
      # constrained — pinned against the live information_schema, not
      # the migration file, so a reintroduction (or a slack constraint)
      # fails here even if a snapshot drifts.
      rows =
        SQL.query!(
          Repo,
          "SELECT column_name, is_nullable FROM information_schema.columns WHERE table_name = 'users'",
          []
        ).rows

      columns = Map.new(rows, fn [name, nullable] -> {name, nullable} end)
      refute Map.has_key?(columns, "email"), "the legacy users.email column must not exist"
      assert columns["username"] == "NO", "users.username must be NOT NULL"
    end

    test "mints UUIDv7 ids (ADR-0032)" do
      first = User.create!("a@fluxvale.com", %{}, authorize?: false)
      second = User.create!("b@fluxvale.com", %{}, authorize?: false)

      # Ordering is deliberately NOT asserted — approximate, never a contract
      assert v7?(first.id) and v7?(second.id)
    end

    test "defaults platform_role to :user and stores the address case-insensitively" do
      user = User.create!("someone@fluxvale.com", %{}, authorize?: false)

      assert user.platform_role == :user

      # #287: the address lives in the signup row (citext), not a column
      assert [%{address: address}] =
               UserEmail
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read!(authorize?: false)

      assert to_string(address) == "someone@fluxvale.com"
    end

    test "rejects unknown platform roles" do
      assert {:error, %Ash.Error.Invalid{}} =
               User.create("someone@fluxvale.com", %{platform_role: :wizard}, authorize?: false)
    end

    test "enforces unique emails across cases (citext)" do
      User.create!("mixed@fluxvale.com", %{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               User.create("MIXED@fluxvale.com", %{}, authorize?: false)
    end

    test "is gated on the platform-admin policy" do
      admin = bootstrap_admin("admin@fluxvale.com")
      regular = User.create!("regular@fluxvale.com", %{}, authorize?: false)

      # A non-admin actor is forbidden…
      assert {:error, %Ash.Error.Forbidden{}} =
               User.create(
                 "blocked@fluxvale.com",
                 %{},
                 actor: regular,
                 authorize?: true
               )

      # …while a platform admin manages users (ADR-0027 admin surfaces).
      assert {:ok, %User{platform_role: :user}} =
               User.create("created@fluxvale.com", %{}, actor: admin, authorize?: true)
    end

    # The signup row (#285 T3 §5, #287): the account is table-backed
    # from birth — the :email argument lands as the verified primary
    # row; the users table carries no address.
    test "a fresh create writes one verified primary user_emails row" do
      user = User.create!("mirrored@x.test", %{}, authorize?: false)

      rows =
        UserEmail
        |> Ash.Query.filter(user_id == ^user.id)
        |> Ash.read!(authorize?: false)

      assert [row] = rows
      refute is_nil(row.verified_at)
      assert row.is_primary
      assert to_string(row.address) == "mirrored@x.test"
    end

    test "create refuses an address another account holds as a pending claim" do
      holder = User.create!("holder@x.test", %{}, authorize?: false)

      {:ok, _claim} =
        UserEmail.add("t3-contested@x.test", %{user: holder}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               User.create("t3-contested@x.test", %{}, authorize?: false)
    end

    test "create refuses a non-deliverable address — the mirror rides :add's validation" do
      assert {:error, %Ash.Error.Invalid{}} =
               User.create("t3-not-an-email", %{}, authorize?: false)
    end
  end

  describe "get_by_email/1" do
    test "matches case-insensitively" do
      created = User.create!("MiXeD@fluxvale.com", %{}, authorize?: false)

      assert {:ok, found} =
               User.get_by_email("mixed@FLUXVALE.com", authorize?: false)

      assert found.id == created.id
    end

    test "a pending claim never resolves — only verified rows are identity (#285 T3)" do
      user = User.create!("pend-holder@x.test", %{}, authorize?: false)

      {:ok, _claim} =
        UserEmail.add("pending-claim@x.test", %{user: user}, authorize?: false)

      assert {:error, _not_found} = User.get_by_email("pending-claim@x.test", authorize?: false)
    end

    test "an unknown address is not found" do
      assert {:error, _not_found} = User.get_by_email("nobody@nowhere.test", authorize?: false)
    end
  end

  describe "username derivation" do
    test "derives the username from the email local part" do
      user = User.create!("terence@x.test", %{}, authorize?: false)

      assert user.username == "terence"
    end

    test "colliding local parts probe -2" do
      User.create!("terence@one.test", %{}, authorize?: false)
      second = User.create!("terence@two.test", %{}, authorize?: false)

      assert second.username == "terence-2"
    end

    test "uppercase local parts normalize to lowercase" do
      user = User.create!("TeReNcE@x.test", %{}, authorize?: false)

      assert user.username == "terence"
    end

    test "degenerate local parts fall back to the user base, suffixed on collision" do
      # "+@…" sanitizes to an empty username — the create action
      # exercises the fallback through the real path (mirrors the
      # org-slug degenerate test).
      first = User.create!("+@one.test", %{}, authorize?: false)
      second = User.create!("+@two.test", %{}, authorize?: false)

      assert first.username == "user"
      assert second.username == "user-2"
    end

    test "reserved names suffix instead of deriving bare" do
      user = User.create!("admin@x.test", %{}, authorize?: false)

      assert user.username == "admin-2"
    end

    test "a 64-char local part truncates to a valid username instead of failing the signup" do
      # The #279 lesson: the derivation gives way, the signup succeeds.
      user = User.create!(String.duplicate("a", 64) <> "@x.test", %{}, authorize?: false)

      assert user.username == String.duplicate("a", 39)
      assert valid_shape?(user.username)
    end

    test "truncation re-trims a trailing hyphen the cut exposes" do
      user = User.create!(String.duplicate("a", 38) <> ".b@x.test", %{}, authorize?: false)

      assert user.username == String.duplicate("a", 38)
    end

    test "a suffix eating into the base re-trims the exposed hyphen" do
      # The base hyphen sits exactly at the suffix's budget cut (39-char
      # base, budget 37 for "-2") — without with_suffix's re-trim the
      # colliding user would derive "aaa…--2".
      local = String.duplicate("a", 36) <> "-xy"

      first = User.create!(local <> "@one.test", %{}, authorize?: false)
      assert first.username == local

      second = User.create!(local <> "@two.test", %{}, authorize?: false)
      assert second.username == String.duplicate("a", 36) <> "-2"
      assert valid_shape?(second.username)
    end

    test "keeps a username already on the changeset" do
      # Usernames have no input surface and accept-validation rejects
      # them outright (derivation is the only writer), so a pre-set one
      # can only reach the change from an earlier-listed change — a
      # future slice's. The no-op branch is pinned directly on the
      # change module: the RETURNED changeset must carry the forced
      # value verbatim — one the email would NOT derive (kept@x.test
      # derives "kept"), so always-derive cannot pass this test.
      changeset =
        User
        |> Ash.Changeset.new()
        |> Ash.Changeset.for_create(:create, %{email: "kept@x.test"})
        |> Ash.Changeset.force_change_attribute(:username, "custom-handle")

      result = DeriveUsername.change(changeset, %{}, %{})

      assert %Ash.Changeset{} = result
      assert Ash.Changeset.get_attribute(result, :username) == "custom-handle"
    end

    test "exhausting the probe range falls back to an unguessable suffix" do
      # Occupy the base and every probed suffix user-2..user-100. A
      # chosen username is a state actions can't produce (username is
      # not accepted), so the occupants ride Ash.seed!.
      Enum.each(1..100, fn i ->
        username = if i == 1, do: "user", else: "user-#{i}"

        Ash.Seed.seed!(User, %{username: username})
      end)

      user = User.create!("+@exhausted.test", %{}, authorize?: false)

      # The exact fallback shape: base + "-" + 8 lowercase hex chars —
      # a constant straggler like "user-101" must not pass.
      assert Regex.match?(~r/^user-[0-9a-f]{8}$/, user.username)
      assert valid_shape?(user.username)
    end

    test "the injected probe seam drives suffixing (the migration's path)" do
      # The backfill injects a raw-SQL closure; the algorithm must not
      # care what probes the names. A scripted taken/free sequence
      # picks the next suffix.
      taken_then_free? = fn
        "terence" -> false
        _free -> true
      end

      assert DeriveUsername.derive_unique("terence@x.test", taken_then_free?) == "terence-2"
    end

    test "an always-taken injected probe reaches the random fallback" do
      username = DeriveUsername.derive_unique("terence@x.test", fn _taken -> false end)

      assert Regex.match?(~r/^terence-[0-9a-f]{8}$/, username)
      assert valid_shape?(username)
    end

    test "reserved names suffix even on the injected probe path" do
      # reserved? is algorithm-level, probe-independent — a probe-only
      # reserved check would let the migration derive bare admin.
      assert DeriveUsername.derive_unique("admin@x.test", fn _taken -> true end) == "admin-2"
    end
  end

  describe "get_by_username/1" do
    test "finds a user by username" do
      created = User.create!("findme@x.test", %{}, authorize?: false)

      assert {:ok, found} = User.get_by_username("findme", authorize?: false)

      assert found.id == created.id
    end

    test "errors on an unknown username" do
      assert {:error, %Ash.Error.Invalid{}} =
               User.get_by_username("nobody-here", authorize?: false)
    end
  end

  describe "set_username/2 (the settings rename — #285 T5)" do
    test "renames the account, touching nothing else" do
      user = User.create!("renamable@x.test", %{}, authorize?: false)

      assert {:ok, renamed} = rename(user, "new-handle", user)

      assert renamed.username == "new-handle"
      assert renamed.id == user.id

      # the rename touches nothing else — the signup row stands
      assert [%{address: address}] =
               UserEmail
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read!(authorize?: false)

      assert to_string(address) == "renamable@x.test"
    end

    test "rejects an uppercase, a 1-char, a too-long, and a hyphen-edged name (DeriveUsername's rules)" do
      user = User.create!("shapey@x.test", %{}, authorize?: false)
      too_long = String.duplicate("a", 40)

      for {bad, problem} <- [
            {"Upper", "must use only lowercase letters"},
            {"a", "must be at least 2 characters"},
            {too_long, "must be at most 39 characters"},
            {"-leading", "must use only lowercase letters"},
            {"trailing-", "must use only lowercase letters"}
          ] do
        assert {:error, error} = rename(user, bad, user)
        assert first_message(error) =~ problem, "#{inspect(bad)} should fail: #{problem}"
      end

      assert {:ok, unchanged} = User.get_by_username("shapey", authorize?: false)
      assert unchanged.id == user.id
    end

    test "rejects a reserved name" do
      user = User.create!("reserved@x.test", %{}, authorize?: false)

      assert {:error, error} = rename(user, "admin", user)
      assert first_message(error) =~ "is reserved"
    end

    test "a platform admin claims a reserved name (#870)" do
      admin = bootstrap_admin("admin@fluxvale.com")

      # The #870 arm: the reserved-list rule does not stop the platform's
      # own admin (the #754 org-slug precedent) — "admin" is claimable.
      # The actor rides the BUILD call: ValidUsername runs eagerly at
      # for_update, so a late-attached actor is invisible to it — the
      # same shape the settings form uses (AshPhoenix.Form.for_update
      # carries actor: user).
      assert {:ok, updated} = admin_rename(admin, "admin", admin)
      assert updated.username == "admin"

      # The exemption is the reserved arm only — shape still binds admins.
      assert {:error, error} = admin_rename(updated, "bad_name!", admin)
      assert first_message(error) =~ "must use only lowercase"
    end

    test "format_problem/1 stays the plain rule set — reserved stays reserved" do
      # The 1-arity is the non-admin contract (#870): reserved_ok defaults
      # to false, so the plain call and the explicit false agree, and only
      # the 2-arity's true opens the reserved arm.
      assert DeriveUsername.format_problem("admin") == "is reserved"
      assert DeriveUsername.format_problem("admin", false) == "is reserved"
      assert DeriveUsername.format_problem("admin", true) == nil
      assert DeriveUsername.format_problem("bad_name!") =~ "must use only lowercase"
    end

    test "rejects a blank name" do
      user = User.create!("blanky@x.test", %{}, authorize?: false)

      assert {:error, error} = rename(user, "", user)
      assert first_message(error) =~ "is required"
    end

    test "a taken username fails with the identity's message" do
      # seed! is the sanctioned bypass: a chosen username is a state the
      # create action can't produce (username is not accepted there).
      occupant = Ash.Seed.seed!(User, %{username: "taken-name"})
      assert occupant.username == "taken-name"

      user = User.create!("contender@x.test", %{}, authorize?: false)

      assert {:error, error} = rename(user, "taken-name", user)
      assert first_message(error) =~ "has already been taken"
    end

    test "a user renames only their own record — Forbidden, and the admin keeps its grant" do
      target = User.create!("target-of@x.test", %{}, authorize?: false)
      actor = User.create!("actor-of@x.test", %{}, authorize?: false)
      admin = bootstrap_admin("admin@fluxvale.com")

      assert {:error, %Ash.Error.Forbidden{}} = rename(target, "hijacked", actor)

      assert {:ok, renamed} = rename(target, "admin-renamed", admin)
      assert renamed.username == "admin-renamed"
    end

    test "a run without the username changes nothing (where: changing posture)" do
      user = User.create!("nochange@x.test", %{}, authorize?: false)

      assert {:ok, same} =
               user
               |> Ash.Changeset.for_update(:set_username, %{})
               |> Ash.update(actor: user, authorize?: true)

      assert same.username == user.username
    end

    defp rename(user, username, actor) do
      user
      |> Ash.Changeset.for_update(:set_username, %{username: username})
      |> Ash.update(actor: actor, authorize?: true)
    end

    # The admin arm's invocation shape: the actor rides for_update, since
    # ValidUsername runs eagerly there and cannot see an actor attached
    # only at Ash.update. Mirrors the settings/onboarding forms, which
    # build with actor: user (the same eager-validation posture).
    defp admin_rename(user, username, admin) do
      user
      |> Ash.Changeset.for_update(:set_username, %{username: username}, actor: admin)
      |> Ash.update(actor: admin, authorize?: true)
    end

    # The first field message of an Invalid error class ("is reserved",
    # "has already been taken", …).
    defp first_message(%Ash.Error.Invalid{errors: errors}) do
      errors
      |> Enum.find(&is_binary(Map.get(&1, :message)))
      |> then(&Map.get(&1, :message))
    end
  end

  describe "finish_onboarding/2 (the #831 first-run stamp)" do
    test "stamps a nil account with the server time" do
      user = User.create!("stampee@x.test", %{}, authorize?: false)

      # nil for every existing account — the W2 gate's "not walked yet"
      refute user.onboarded_at

      assert {:ok, stamped} = finish(user, user)
      assert %DateTime{} = stamped.onboarded_at
    end

    test "a different user is Forbidden" do
      target = User.create!("stamp-target@x.test", %{}, authorize?: false)
      actor = User.create!("stamp-actor@x.test", %{}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} = finish(target, actor)
    end

    test "an admin PAT on another user is Forbidden — the blanket stands down at the machine API" do
      target = User.create!("stamp-admin-target@x.test", %{}, authorize?: false)
      admin = bootstrap_admin("admin@fluxvale.com")

      # The #644 blanket admits admins only OUTSIDE the machine API, so a
      # plain admin call rides the bypass, not this policy. The process
      # mark switches it off (the admin_authority pattern) — the call then
      # meets the action's own policy, the stance every PAT caller meets:
      # owner-only, and no admin arm exists to fall back to.
      key = CallOutsideMachineApi.machine_api_mark_key()
      Process.put(key, true)

      assert {:error, %Ash.Error.Forbidden{}} = finish(target, admin)
    after
      Process.delete(CallOutsideMachineApi.machine_api_mark_key())
    end

    test "a plain platform admin on another user is admitted — the #644 blanket rides this action" do
      # The blanket is resource-level doctrine: a session-shaped admin
      # passes before this action's owner-only policy ever answers. Pinned
      # so a future scoping of the blanket away from :finish_onboarding
      # flips THIS test loudly instead of drifting silently.
      target = User.create!("stamp-blanket-target@x.test", %{}, authorize?: false)
      admin = bootstrap_admin("admin@fluxvale.com")

      assert {:ok, stamped} = finish(target, admin)
      assert %DateTime{} = stamped.onboarded_at
    end

    test "the stamp is server-set — a client-carried onboarded_at is refused" do
      user = User.create!("stamp-server@x.test", %{}, authorize?: false)

      # accept([]): the action takes no input, so a payload carrying the
      # private attribute is NoSuchInput — nothing client-side reaches
      # the stamp, and the server-side set_attribute is the only writer.
      assert {:error, %Ash.Error.Invalid{}} =
               user
               |> Ash.Changeset.for_update(:finish_onboarding, %{
                 onboarded_at: ~U[2020-01-01T00:00:00Z]
               })
               |> Ash.update(actor: user, authorize?: true)

      assert {:ok, stamped} = finish(user, user)
      assert %DateTime{} = stamped.onboarded_at
    end

    test "a repeat call keeps the first stamp (keep-first, not re-stamp)" do
      user = User.create!("keep-first@x.test", %{}, authorize?: false)

      assert {:ok, first} = finish(user, user)
      assert %DateTime{} = first.onboarded_at

      assert {:ok, second} = finish(first, user)
      assert second.onboarded_at == first.onboarded_at
    end

    test "a stale snapshot does not clobber the stamp (the expr reads the ROW)" do
      user = User.create!("stale-snapshot@x.test", %{}, authorize?: false)

      # The create!-returned struct is itself a pre-stamp snapshot (nil
      # in memory). The row gets stamped through a fresh load…
      fresh = Ash.get!(User, user.id, authorize?: false)
      assert {:ok, stamped} = finish(fresh, user)

      # …and the stale struct now lags the row. The keep-first expr is
      # data-layer rendered against the ROW, never the caller's struct,
      # so this call keeps the original stamp instead of re-stamping.
      assert {:ok, kept} = finish(user, user)
      assert kept.onboarded_at == stamped.onboarded_at
    end

    defp finish(user, actor) do
      user
      |> Ash.Changeset.for_update(:finish_onboarding, %{})
      |> Ash.update(actor: actor, authorize?: true)
    end
  end

  # The derivation contract: `[a-z0-9][a-z0-9-]*[a-z0-9]`, 2–39 chars.
  defp valid_shape?(username) do
    Regex.match?(~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/, username) and
      String.length(username) in 2..39
  end

  # Version nibble: first hex char of the third UUID group (byte 15, 0-indexed 14)
  defp v7?(id) do
    <<_prefix::binary-size(14), version, _rest::binary>> = to_string(id)
    version == ?7
  end
end
