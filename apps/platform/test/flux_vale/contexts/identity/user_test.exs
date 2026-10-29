defmodule FluxVale.Identity.UserTest do
  @moduledoc false

  # Not async: this file's exhaustion/degenerate tests speculate on the
  # same users_unique_username_index keys ("user"…"user-100") that
  # provision_personal_org_test's degenerate fixtures derive — concurrent
  # sandbox transactions deadlock there (40P01: the pair alone 7/10,
  # serialized 0/8). Non-async cases run after all async ones, so the
  # files never overlap.
  use FluxVale.DataCase, async: false

  alias FluxVale.Identity.User
  alias FluxVale.Identity.User.DeriveUsername
  alias FluxVale.Identity.UserEmail

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
    test "mints UUIDv7 ids (ADR-0032)" do
      first = User.create!("a@fluxvale.com", %{}, authorize?: false)
      second = User.create!("b@fluxvale.com", %{}, authorize?: false)

      # Ordering is deliberately NOT asserted — approximate, never a contract
      assert v7?(first.id) and v7?(second.id)
    end

    test "defaults platform_role to :user and stores email case-insensitively" do
      user = User.create!("someone@fluxvale.com", %{}, authorize?: false)

      assert user.platform_role == :user
      assert to_string(user.email) == "someone@fluxvale.com"
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

    # The mirror (#285 T3 §5): the account is table-backed from birth.
    test "a fresh create leaves users.email AND one verified primary user_emails row" do
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

        Ash.Seed.seed!(User, %{email: "occupant-#{i}@x.test", username: username})
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
