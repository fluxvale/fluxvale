defmodule FluxVale.Accounts.Operations.PersonalOrgForUser do
  @moduledoc """
  Looks up a user's personal org — the account-surface org (#119): the
  one whose `personal_owner_id` names them (#408). Returns `:none` when
  the user has none (an org-less row, or only unmarked team orgs).

  The marker is the personal-org fact's only writer: provisioning
  stamps it at signup, and the #408 backfill stamped it once over
  pre-existing rows — implementing the earliest-owned derivation this
  operation used to run live. That derivation retires here: it was the
  identity spec's deferred T7 answer, and user-created orgs (#408)
  would break any ownership-derived pick, so the read is the explicit
  marker now.

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
      |> Ash.Query.filter(personal_owner_id == ^user_id)
      # Sort + limit stay: the unique index already pins the answer to
      # one row, and a deterministic pick costs nothing.
      |> Ash.Query.sort(created_at: :asc, id: :asc)
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
