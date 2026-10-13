defmodule FluxVale.TestSupport.SessionHelpers do
  @moduledoc false

  # Web-test preconditions (#74): a user and a token-backed session conn,
  # the same shape SessionController writes. Jwt.token_for_user/4 stores
  # the token (purpose :user) — the store row is what the on_mount gate's
  # token-presence check requires.

  alias AshAuthentication.Jwt
  alias FluxVale.Accounts
  alias FluxVale.Billing
  alias FluxVale.Identity.User

  # Same funded-org posture as AccountsFixtures.user!/1 — kept inline
  # (not delegated): the @fluxvale.com domain below is load-bearing for
  # the AccessRule tests; #124's deploy gate needs the funding.
  @spec user!() :: FluxVale.Identity.User.t()
  def user! do
    email = "web-#{System.unique_integer()}@fluxvale.com"

    user = User.create!(email, %{}, authorize?: false)
    {:ok, org} = Accounts.personal_org_for_user(user.id, authorize?: false)
    {:ok, _grant} = Billing.grant_credits(org, 10_000)
    user
  end

  @spec sign_in(Plug.Conn.t(), FluxVale.Identity.User.t()) :: Plug.Conn.t()
  def sign_in(conn, user) do
    {:ok, token, _claims} = Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  @spec user_with_session(Plug.Conn.t()) :: {FluxVale.Identity.User.t(), Plug.Conn.t()}
  def user_with_session(conn) do
    user = user!()
    {user, sign_in(conn, user)}
  end
end
