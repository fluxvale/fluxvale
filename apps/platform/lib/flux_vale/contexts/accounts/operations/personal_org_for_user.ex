defmodule FluxVale.Accounts.Operations.PersonalOrgForUser do
  @moduledoc """
  Looks up the personal organization a user owns (their `:owner`
  membership) — the org instances and wallets resolve against (#119).
  Returns `:none` when the user owns no org.

  Authorization propagates from the caller (never hard-coded): system
  contexts (metering settlement, M5) pass `authorize?: false` explicitly;
  actor-context callers (the instance org resolution on create) pass the
  actor through.
  """

  alias FluxVale.Accounts.Organization

  require Ash.Query

  @spec call(String.t() | Ash.UUID.t(), keyword()) ::
          {:ok, Organization.t()} | :none | {:error, term()}
  def call(user_id, opts \\ []) when is_binary(user_id) do
    query =
      Organization
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(memberships.user_id == ^user_id and memberships.role == :owner)
      |> Ash.Query.limit(1)

    case Ash.read(query,
           actor: Keyword.get(opts, :actor),
           authorize?: Keyword.get(opts, :authorize?, true)
         ) do
      {:ok, [org | _rest]} ->
        {:ok, org}

      {:ok, []} ->
        :none

      # defensive: DB read failure, not simulatable under the sandbox
      # coveralls-ignore-start
      {:error, _reason} = error ->
        error
        # coveralls-ignore-stop
    end
  end
end
