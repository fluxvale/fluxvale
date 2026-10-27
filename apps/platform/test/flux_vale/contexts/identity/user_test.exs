defmodule FluxVale.Identity.UserTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User
  alias FluxVale.Identity.User.DeriveUsername

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
  end

  describe "get_by_email/1" do
    test "matches case-insensitively" do
      created = User.create!("MiXeD@fluxvale.com", %{}, authorize?: false)

      assert {:ok, found} =
               User.get_by_email("mixed@FLUXVALE.com", authorize?: false)

      assert found.id == created.id
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

    test "keeps a username already on the changeset" do
      # Usernames have no input surface and accept-validation rejects
      # them outright (derivation is the only writer), so a pre-set one
      # can only reach the change from an earlier-listed change — a
      # future slice's. The no-op branch is pinned directly on the
      # change module.
      changeset =
        User
        |> Ash.Changeset.new()
        |> Ash.Changeset.for_create(:create, %{email: "kept@x.test"})
        |> Ash.Changeset.force_change_attribute(:username, "kept")

      assert %Ash.Changeset{} = DeriveUsername.change(changeset, %{}, %{})
      assert Ash.Changeset.get_attribute(changeset, :username) == "kept"
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

      assert String.starts_with?(user.username, "user-")
      assert user.username not in ["user", "user-2", "user-100"]
      assert valid_shape?(user.username)
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
