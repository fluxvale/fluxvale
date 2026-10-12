defmodule FluxVale.TestSupport.AccountsFixtures do
  @moduledoc """
  Preconditions for Accounts-coupled tests (#119): a user — whose personal
  org the `User.create` JIT change provisions — and that org, read back
  through actions with `authorize?: false` (the repo's bootstrap posture,
  mirroring seeds).
  """

  alias FluxVale.Accounts
  alias FluxVale.Identity.User

  @doc """
  Creates a user via the create action; the JIT change provisions the
  personal org as a side effect. `local_part` pins the org slug base —
  callers needing colliding slugs pass the same local part with a
  colliding domain, or generate their own addresses.
  """
  @spec user!(String.t() | nil) :: User.t()
  def user!(local_part \\ nil) do
    email = "#{local_part || "user-#{System.unique_integer([:positive])}"}@fluxvale.test"

    User.create!(email, %{}, authorize?: false)
  end

  @doc "The user's personal org (loud failure if JIT provisioning didn't run)."
  @spec personal_org!(User.t()) :: FluxVale.Accounts.Organization.t()
  def personal_org!(%User{} = user) do
    {:ok, org} = Accounts.personal_org_for_user(user.id, authorize?: false)
    org
  end
end
