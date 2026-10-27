defmodule FluxVale.Accounts.Operations.OrganizationsForUser do
  @moduledoc """
  Lists the organizations a user belongs to — the org switcher's read
  (#276): one authorized query over the user's memberships with
  `:organization` loaded, so each row carries org + role together.

  Authorization propagates from the caller (never hard-coded), exactly
  like `PersonalOrgForUser`. With an actor, the actor is the authority:
  the query returns only the actor's own memberships — orgs they belong
  to — and the `user_id` argument cannot widen that (a co-member of a
  shared org passes the read policy for the whole org, so the row scope
  is the actor's, per the `SetOrganizationFromActor` stance). The
  `user_id` argument scopes the system path (`authorize?: false`, seeds
  and preconditions). A caller with no actor and the default
  `authorize?` is Forbidden.
  """

  alias FluxVale.Accounts.Membership

  require Ash.Query

  @spec call(String.t() | Ash.UUID.t(), keyword()) ::
          {:ok, [Membership.t()]} | {:error, term()}
  def call(user_id, opts \\ []) when is_binary(user_id) do
    base_query =
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.load(:organization)

    query =
      case Keyword.get(opts, :actor) do
        nil ->
          base_query

        actor ->
          Ash.Query.filter(base_query, user_id == ^actor.id)
      end

    case Ash.read(query,
           actor: Keyword.get(opts, :actor),
           authorize?: Keyword.get(opts, :authorize?, true)
         ) do
      {:ok, memberships} ->
        {:ok, memberships}

      # The no-actor/default-authorize? caller — Forbidden by policy.
      {:error, _reason} = error ->
        error
    end
  end
end
