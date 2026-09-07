defmodule FluxVale.Identity.PatActionTest do
  @moduledoc false

  use FluxVale.DataCase, async: true

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias AshAuthentication.TokenResource.Actions
  alias FluxVale.Identity.User

  # PATs mint under the platform-admin policy (generic actions authorize by
  # default) — same bootstrap shape as user_test; the operator/IEx path is
  # the authorize?: false variant exercised in the policy test below.
  defp admin!(email) do
    case User.get_by_email(email, authorize?: false) do
      {:ok, existing} -> existing
      {:error, _not_found} -> User.create!(email, %{platform_role: :admin}, authorize?: false)
    end
  end

  describe "User.mint_pat/1" do
    setup do
      %{admin: admin!("admin@fluxvale.com")}
    end

    test "mints a PAT that authenticates as the owner", %{admin: admin} do
      user = User.create!("pat-owner@fluxvale.com", %{}, authorize?: false)

      assert {:ok, token} = User.mint_pat("pat-owner@fluxvale.com", actor: admin)
      assert is_binary(token)

      assert {:ok, %{"sub" => subject}} = Jwt.peek(token)
      assert subject =~ user.id
    end

    test "mints a long-lived token (365 days, not the 60-day session TTL)", %{admin: admin} do
      User.create!("longlived@fluxvale.com", %{}, authorize?: false)

      assert {:ok, token} = User.mint_pat("longlived@fluxvale.com", actor: admin)
      assert {:ok, %{"exp" => exp, "iat" => iat}} = Jwt.peek(token)

      # exp is stamped from the clock at mint-time, iat at sign-time — a
      # second boundary can fall between, so near-equality, not equality
      assert_in_delta exp - iat, 365 * 24 * 60 * 60, 5
    end

    test "returns {:error, _} for an unknown email", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               User.mint_pat("nobody@fluxvale.com", actor: admin)
    end

    test "is gated on the platform-admin policy" do
      User.create!("blocked@fluxvale.com", %{}, authorize?: false)
      regular = User.create!("regular@fluxvale.com", %{}, authorize?: false)

      # No actor → forbidden…
      assert {:error, %Ash.Error.Forbidden{}} =
               User.mint_pat("blocked@fluxvale.com", authorize?: true)

      # …non-admin actor → forbidden…
      assert {:error, %Ash.Error.Forbidden{}} =
               User.mint_pat("blocked@fluxvale.com", actor: regular)

      # …while the operator path (IEx) mints without an actor
      assert {:ok, _token} = User.mint_pat("blocked@fluxvale.com", authorize?: false)
    end

    test "rides the revocable token store — revocation severs the bearer", %{admin: admin} do
      user = User.create!("revoke@fluxvale.com", %{}, authorize?: false)

      assert {:ok, token} = User.mint_pat("revoke@fluxvale.com", actor: admin)

      # store_all_tokens?: the PAT rides the same store/presence machinery
      # as a session (bearer authenticates before revocation…)
      assert bearer_user(token).id == user.id

      # …and the framework revoke path upserts the revocation row — see
      # Token's moduledoc for why not a code_interface on :revoke_token
      assert :ok = Actions.revoke(FluxVale.Identity.Token, token)

      refute bearer_user(token)
    end
  end

  # The real bearer path (JWT verify → revocation + presence checks →
  # actor), same helper token_test uses — and the one the /api/me
  # pipeline will adopt (#24)
  defp bearer_user(token) do
    :get
    |> Plug.Test.conn("/")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Helpers.retrieve_from_bearer(:flux_vale)
    |> Map.get(:assigns)
    |> Map.get(:current_user)
  end
end
