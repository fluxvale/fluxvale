defmodule FluxVale.Accounts.Operations.OrganizationsForUser do
  @moduledoc """
  Lists the organizations a user belongs to — the org switcher's read
  (#276): one authorized query over the user's memberships with
  `:organization` loaded, so each row carries org + role together.

  Authorization propagates from the caller (never hard-coded), exactly
  like `PersonalOrgForUser`: an actor reading their own memberships
  passes the Membership read policy (`relates_to_actor_via`); rows for
  orgs the actor doesn't belong to filter out.
  """

  alias FluxVale.Accounts.Membership

  require Ash.Query

  @spec call(String.t() | Ash.UUID.t(), keyword()) ::
          {:ok, [Membership.t()]} | {:error, term()}
  def call(user_id, opts \\ []) when is_binary(user_id) do
    query =
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.load(:organization)

    case Ash.read(query,
           actor: Keyword.get(opts, :actor),
           authorize?: Keyword.get(opts, :authorize?, true)
         ) do
      {:ok, memberships} ->
        {:ok, memberships}

      # defensive: DB read failure, not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end
end
