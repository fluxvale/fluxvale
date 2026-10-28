defmodule FluxVale.Ops.OwnerSignInTest do
  @moduledoc """
  The break-glass sign-in path (#165): the owner gate (`OWNER_EMAIL`, else
  the single platform admin), the printed code, and the fact that the
  printed code is the one the normal verify path accepts.
  """

  # Not async: the gate reads OWNER_EMAIL from the process environment,
  # which is global — async cases would race it.
  use FluxVale.DataCase, async: false

  import ExUnit.CaptureIO

  alias FluxVale.Identity
  alias FluxVale.Identity.User
  alias FluxVale.Identity.UserEmail
  alias FluxVale.Ops.AccessRule
  alias FluxVale.Ops.OwnerSignIn
  alias FluxVale.TestSupport.AccountsFixtures

  setup do
    original = System.get_env("OWNER_EMAIL")
    System.delete_env("OWNER_EMAIL")

    on_exit(fn ->
      if original,
        do: System.put_env("OWNER_EMAIL", original),
        else: System.delete_env("OWNER_EMAIL")
    end)

    %{email: "owner-#{System.unique_integer([:positive])}@fluxvale.test"}
  end

  defp admin!(email \\ nil) do
    email = email || "admin-#{System.unique_integer([:positive])}@fluxvale.test"
    User.create!(email, %{platform_role: :admin}, authorize?: false)
    email
  end

  describe "owner_email/0" do
    test "OWNER_EMAIL names the owner, trimmed, ahead of any admin", %{email: email} do
      admin!()
      System.put_env("OWNER_EMAIL", "  #{email}  ")

      assert OwnerSignIn.owner_email() == email
    end

    test "falls back to the environment's single platform admin" do
      admin = admin!()

      assert OwnerSignIn.owner_email() == admin
    end

    test "blank OWNER_EMAIL is unset" do
      admin = admin!()
      System.put_env("OWNER_EMAIL", "   ")

      assert OwnerSignIn.owner_email() == admin
    end

    test "no admin is an operator decision, not a guess" do
      AccountsFixtures.user!()

      assert_raise RuntimeError, ~r/0 platform admins found/, fn -> OwnerSignIn.owner_email() end
    end

    test "several admins raises with the count" do
      admin!()
      admin!()

      assert_raise RuntimeError, ~r/2 platform admins found/, fn -> OwnerSignIn.owner_email() end
    end

    # #285 T3: the fallback reads the PRIMARY VERIFIED address through
    # user_emails — users.email is a frozen mirror.
    test "the single-admin fallback reads the admin's primary verified address" do
      admin = User.get_by_email!(admin!(), authorize?: false)
      switched = "switched-#{System.unique_integer([:positive])}@fluxvale.test"

      {:ok, row} = UserEmail.add(switched, %{user: admin}, authorize?: false)
      {:ok, _verified} = UserEmail.mark_verified(row, authorize?: false)
      {:ok, _promoted} = UserEmail.set_primary(row, actor: admin)

      assert OwnerSignIn.owner_email() == switched
    end

    test "an admin with no verified primary is drift — the operator decides" do
      # A user without user_emails rows is a state actions cannot produce
      # (the create mirror stamps one) — seed! is the sanctioned bypass.
      Ash.Seed.seed!(User, %{
        email: "drift-admin-#{System.unique_integer([:positive])}@fluxvale.test",
        platform_role: :admin
      })

      assert_raise RuntimeError, ~r/no verified primary email/, fn ->
        OwnerSignIn.owner_email()
      end
    end
  end

  describe "issue_code/1" do
    test "prints a code the normal verify path accepts, with the sign-in URL", %{email: email} do
      System.put_env("OWNER_EMAIL", email)

      output = capture_io(fn -> assert :ok = OwnerSignIn.issue_code() end)

      assert [code] = Regex.run(~r/code for #{email}: (\d{6})/, output, capture: :all_but_first)
      assert output =~ "/sign-in"
      assert output =~ "Expires in 10 minutes"

      # The whole point: the printed code is the one production verifies —
      # a first success also JIT-provisions the account and its org.
      assert {:ok, %{email: verified}, token} = Identity.verify_auth_code(email, code)
      assert to_string(verified) == email
      assert is_binary(token)
    end

    test "hands the code to an injected deliver", %{email: email} do
      System.put_env("OWNER_EMAIL", email)

      deliver = fn _recipient, code ->
        send(self(), {:delivered, code})
        {:ok, :printed}
      end

      assert :ok = OwnerSignIn.issue_code(deliver)
      assert_receive {:delivered, code}

      assert {:ok, _user, _token} = Identity.verify_auth_code(email, code)
    end

    test "a second request inside the throttle window names the wait", %{email: email} do
      System.put_env("OWNER_EMAIL", email)
      assert :ok = OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)

      assert_raise RuntimeError, ~r/throttled.*60 seconds/, fn ->
        OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
      end
    end

    test "an AccessRule denial raises instead of issuing", %{email: email} do
      # Any row turns the empty-then-close allowlist on: this one admits
      # fluxvale.com only, so the owner address here is not allowed.
      AccessRule.create!(%{domain: "fluxvale.com"}, authorize?: false)
      System.put_env("OWNER_EMAIL", email)

      assert_raise RuntimeError, ~r/AccessRule/, fn ->
        OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
      end
    end

    test "a delivery failure raises — the code exists only on stdout", %{email: email} do
      System.put_env("OWNER_EMAIL", email)

      assert_raise RuntimeError, ~r/request failed: :delivery_failed/, fn ->
        OwnerSignIn.issue_code(fn _recipient, _code -> {:error, :boom} end)
      end
    end

    # #172: a typo'd OWNER_EMAIL still mints (an operator decision) but
    # names the mismatch — the session it provisions is not the admin's.
    test "warns when OWNER_EMAIL does not match the platform admin", %{email: email} do
      admin = admin!()
      System.put_env("OWNER_EMAIL", email)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
        end)

      assert log =~ "does not match the platform admin #{admin}"
      assert log =~ "issuing a code for #{email} anyway"
    end

    test "no warning when OWNER_EMAIL is the platform admin" do
      admin = admin!()
      System.put_env("OWNER_EMAIL", admin)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
        end)

      refute log =~ "does not match"
    end

    test "no warning on the single-admin fallback — the resolved address is the admin" do
      admin!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
        end)

      refute log =~ "does not match"
    end
  end

  describe "FluxVale.Release.owner_signin_code/0" do
    test "the release entrypoint issues through the same gate", %{email: email} do
      System.put_env("OWNER_EMAIL", email)

      output = capture_io(fn -> assert :ok = FluxVale.Release.owner_signin_code() end)

      assert output =~ "Owner sign-in code for #{email}"
    end
  end
end
