defmodule FluxVale.TestSupport.ApiPat do
  @moduledoc """
  Mints a scoped PAT for the /api/v1 route tests (#360).

  The scoped-PAT seam (`FluxVale.Identity.mint_pat/3`): the actor
  self-mints — the create policy's own gate — carrying exactly the
  scopes the family under test needs, so every refusal the suites
  assert is a POLICY refusal, never the boundary scope gate (its 403
  detail reads "token is missing the required scope" — a different
  failure that must never satisfy these proofs).
  """

  alias FluxVale.Identity
  alias FluxVale.Identity.User

  # The S1 catalog's grantable scopes, for the proofs that cross
  # families (the paywall suite) — every gate passes, so whatever
  # refuses is a policy.
  @full_scopes Enum.map(
                 [:instances, :backups, :gateways],
                 &["#{&1}:write", "#{&1}:read"]
               )
               |> List.flatten()
               |> Kernel.++(Enum.map([:wallet, :catalog], &"#{&1}:read"))

  @spec mint!(FluxVale.Identity.User.t() | String.t(), [String.t()]) :: String.t()
  # #287: takes the user directly (the suites' shape) or an address
  # (the lookup resolves it through user_emails — the users table
  # carries no address).
  def mint!(%FluxVale.Identity.User{} = user, scopes) do
    {:ok, %{token: raw}} =
      Identity.mint_pat(user, %{user_id: user.id, name: "route-test", scopes: scopes})

    raw
  end

  def mint!(email, scopes) do
    user = User.get_by_email!(email, authorize?: false)
    mint!(user, scopes)
  end

  @doc """
  `{user, pat}` for a fresh JIT-provisioned member — welcome-funded,
  never paid. `scopes` defaults to the full S1 catalog. #287: mints
  straight from the user record — the address lookup mint!/1 does is
  for callers that only know an address.
  """
  @spec member!([String.t()]) :: {FluxVale.Identity.User.t(), String.t()}
  def member!(scopes \\ @full_scopes) do
    user = FluxVale.TestSupport.AccountsFixtures.user!()

    {:ok, %{token: raw}} =
      Identity.mint_pat(user, %{user_id: user.id, name: "route-test", scopes: scopes})

    {user, raw}
  end
end
