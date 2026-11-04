defmodule FluxVale.Accounts.Operations.OwnedOrgsForUser do
  @moduledoc """
  Lists the organizations a user OWNS — the feedback islands' org picker
  (fluxvale/fluxvale#412, [ADR-0026](../../../../../docs/adr/00026-feedback-board.md)):
  the write gate is ownership (`ActorIsOrganizationOwner`), so the picker
  offers exactly the orgs the actor may spend a slot for. Mere memberships
  are not listed — a `:member` of a paid org gets nothing.

  Oldest first: the personal org is provisioned in the signup
  transaction, so it is always the first row — the islands' "default to
  the personal org" pick reads it positionally against that fact.

  Authorization propagates from the caller (never hard-coded), exactly
  like `OrganizationsForUser`: with an actor, the actor is the authority
  and the `user_id` argument cannot widen the row set; the `user_id`
  argument scopes the system path (`authorize?: false`, seeds and
  preconditions).
  """

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization

  require Ash.Query

  @spec call(String.t() | Ash.UUID.t(), keyword()) ::
          {:ok, [Organization.t()]} | {:error, term()}
  def call(user_id, opts \\ []) when is_binary(user_id) do
    base_query =
      Membership
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(user_id == ^user_id and role == :owner)
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
        orgs =
          memberships
          |> Enum.map(& &1.organization)
          |> Enum.sort_by(& &1.created_at)

        {:ok, orgs}

      # The no-actor/default-authorize? caller — Forbidden by policy.
      {:error, _reason} = error ->
        error
    end
  end
end
