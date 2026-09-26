defmodule FluxVale.TestSupport.SessionHelpers do
  @moduledoc false

  # Web-test preconditions (#74): a user and a token-backed session conn,
  # the same shape SessionController writes. Jwt.token_for_user/4 stores
  # the token (purpose :user) — the store row is what the on_mount gate's
  # token-presence check requires.

  alias AshAuthentication.Jwt
  alias FluxVale.Identity.User

  @spec user!() :: FluxVale.Identity.User.t()
  def user! do
    User.create!("web-#{System.unique_integer()}@fluxvale.com", %{}, authorize?: false)
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
