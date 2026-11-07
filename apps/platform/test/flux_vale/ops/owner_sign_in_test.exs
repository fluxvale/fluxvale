defmodule FluxVale.Ops.OwnerSignInTest do
  @moduledoc """
  The break-glass sign-in path (#165): the owner gate (`OWNER_EMAIL`, else
  the single platform admin), the printed code, and the fact that the
  printed code is the one the normal verify path accepts. The #502 arms:
  an invited-unaccepted owner gets a re-invite with the accept link
  printed, and a userless external address raises actionable.
  """

  # Not async: the gate reads OWNER_EMAIL from the process environment,
  # which is global — async cases would race it.
  use FluxVale.DataCase, async: false

  import ExUnit.CaptureIO
  import FluxVale.TestSupport.UserInviteHelpers

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

    test "a drift admin under an explicit OWNER_EMAIL still issues — with the warning" do
      # The OWNER_EMAIL address rides the team domain, so the userless
      # code path (the JIT create admits it) is what issues.
      Ash.Seed.seed!(User, %{
        email: "drift-admin-#{System.unique_integer([:positive])}@fluxvale.test",
        platform_role: :admin
      })

      named = "named-#{System.unique_integer([:positive])}@fluxvale.com"
      System.put_env("OWNER_EMAIL", named)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
        end)

      assert log =~ "no verified primary email"
      assert log =~ "that session will not be an admin"
    end
  end

  describe "issue_code/1 — the code path" do
    test "prints a code the normal verify path accepts, with the sign-in URL" do
      # the team domain is what admits the JIT create behind this code
      team = "owner-jit-#{System.unique_integer([:positive])}@fluxvale.com"
      System.put_env("OWNER_EMAIL", team)

      output = capture_io(fn -> assert :ok = OwnerSignIn.issue_code() end)

      assert [code] = Regex.run(~r/code for #{team}: (\d{6})/, output, capture: :all_but_first)
      assert output =~ "/sign-in"
      assert output =~ "Expires in 10 minutes"

      # The whole point: the printed code is the one production verifies —
      # a first success also JIT-provisions the account and its org (the
      # team bypass is what admits the create, #502).
      assert {:ok, %{email: verified}, token} = Identity.verify_auth_code(team, code)

      assert to_string(verified) == team
      assert is_binary(token)
    end

    test "an ACTIVE external owner still prints a code — the gate never asks", %{email: email} do
      System.put_env("OWNER_EMAIL", email)
      User.create!(email, %{}, authorize?: false)

      output = capture_io(fn -> assert :ok = OwnerSignIn.issue_code() end)

      assert output =~ "code for #{email}"
    end

    test "hands the code to an injected deliver" do
      team = "owner-inject-#{System.unique_integer([:positive])}@fluxvale.com"
      System.put_env("OWNER_EMAIL", team)

      deliver = fn _recipient, code ->
        send(self(), {:delivered, code})
        {:ok, :printed}
      end

      assert :ok = OwnerSignIn.issue_code(deliver)
      assert_receive {:delivered, code}

      assert {:ok, _user, _token} = Identity.verify_auth_code(team, code)
    end

    test "a second request inside the throttle window names the wait", %{email: email} do
      System.put_env("OWNER_EMAIL", email)
      User.create!(email, %{}, authorize?: false)

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
      User.create!(email, %{}, authorize?: false)

      assert_raise RuntimeError, ~r/AccessRule/, fn ->
        OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
      end
    end

    test "a delivery failure raises — the code exists only on stdout", %{email: email} do
      System.put_env("OWNER_EMAIL", email)
      User.create!(email, %{}, authorize?: false)

      assert_raise RuntimeError, ~r/request failed: :delivery_failed/, fn ->
        OwnerSignIn.issue_code(fn _recipient, _code -> {:error, :boom} end)
      end
    end

    # #172: a typo'd OWNER_EMAIL still mints (an operator decision) but
    # names the mismatch — the session it provisions is not the admin's.
    test "warns when OWNER_EMAIL does not match the platform admin", %{email: email} do
      admin = admin!()
      System.put_env("OWNER_EMAIL", email)
      User.create!(email, %{}, authorize?: false)

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

  describe "issue_code/1 — the invitation arms (#502)" do
    test "an invited-unaccepted owner gets the accept link printed — never a code" do
      invited = "invited-owner-#{System.unique_integer([:positive])}@partner.example"
      {_user, _raw} = invite_user!(invited)
      System.put_env("OWNER_EMAIL", invited)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          output = capture_io(fn -> assert :ok = OwnerSignIn.issue_code() end)
          send(self(), {:printed, output})
        end)

      assert_receive {:printed, output}

      # Exactly one accept URL: the double-wrap bug (deliver handing a
      # built URL to a printer that wrapped it again) printed the prefix
      # twice — one occurrence is the load-bearing assertion.
      assert length(String.split(output, "/invites/accept?token=")) == 2
      assert output =~ invited
      assert output =~ "works once"
      assert output =~ "the previous link is dead"

      # the log names the re-mint, never the token
      assert log =~ "printing re-mints the accept link"
      refute log =~ "/invites/accept?token="
    end

    test "a userless external address raises actionable — the invite lever is named" do
      stranger = "stranger-#{System.unique_integer([:positive])}@partner.example"
      System.put_env("OWNER_EMAIL", stranger)

      message =
        assert_raise(RuntimeError, fn ->
          OwnerSignIn.issue_code(fn _recipient, _code -> {:ok, :printed} end)
        end).message

      assert message =~ "Invite it first via FluxVale.Identity.invite_user"
      assert message =~ stranger
    end
  end

  describe "FluxVale.Release.owner_signin_code/0" do
    test "the release entrypoint issues through the same gate" do
      team = "owner-release-#{System.unique_integer([:positive])}@fluxvale.com"
      System.put_env("OWNER_EMAIL", team)

      output = capture_io(fn -> assert :ok = FluxVale.Release.owner_signin_code() end)

      assert output =~ "Owner sign-in code for #{team}"
    end
  end

  describe "FluxVale.Release.invite_user/1 (#502, bin/invite)" do
    test "invites through the domain and prints the one-time accept link exactly once" do
      address = "release-invite-#{System.unique_integer([:positive])}@partner.example"

      output = capture_io(fn -> assert :ok = FluxVale.Release.invite_user(address) end)

      assert output =~ "Accept link for #{address}"

      # the double-wrap bug the hostile review caught on the owner arm:
      # one URL, not a URL wrapped in a URL
      assert length(String.split(output, "/invites/accept?token=")) == 2
    end

    test "an invalid address raises actionable" do
      address = "not-an-email-#{System.unique_integer([:positive])}"

      message =
        assert_raise(RuntimeError, fn -> FluxVale.Release.invite_user(address) end).message

      assert message =~ "invite failed for #{address}"
      assert message =~ ":invalid_address"
    end
  end
end
