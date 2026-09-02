defmodule FluxVale.Identity.UserTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias FluxVale.Identity.User

  # The first user is bootstrapped without authorization — there is no actor
  # to authorize before an admin exists (mirrors priv/repo/seeds.exs).
  defp bootstrap_admin(email) do
    case User.get_by_email(email, authorize?: false) do
      {:ok, existing} -> existing
      {:error, _not_found} -> User.create!(email, %{platform_role: :admin}, authorize?: false)
    end
  end

  describe "create/1" do
    test "mints UUIDv7 ids in creation order (ADR-0032)" do
      first = User.create!("a@fluxvale.com", %{}, authorize?: false)
      second = User.create!("b@fluxvale.com", %{}, authorize?: false)

      # Monotonic within a process; version nibble is byte 15 of the string
      assert v7?(first.id) and v7?(second.id)
      assert first.id < second.id
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

  # Version nibble: first hex char of the third UUID group (byte 15, 0-indexed 14)
  defp v7?(id) do
    <<_::binary-size(14), version, _::binary>> = to_string(id)
    version == ?7
  end
end
