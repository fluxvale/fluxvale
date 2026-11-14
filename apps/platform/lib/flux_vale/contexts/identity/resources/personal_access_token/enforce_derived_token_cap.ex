defmodule FluxVale.Identity.PersonalAccessToken.EnforceDerivedTokenCap do
  @moduledoc """
  The per-user cap on live minted tokens (#772).

  The mint route is programmatic, so an unbounded fleet of child
  tokens would multiply the per-token meter. Every derived create —
  one whose provenance names a `minted_parent_id` — takes the parent
  user's row `FOR UPDATE` first, then counts the user's live derived
  rows and refuses at the cap. The lock makes count-and-insert one
  per-user critical section (the `UserEmail.EnforceEmailCap` posture);
  without it two concurrent mints could both count below the cap and
  both land.

  The count is a SQL count, not a row scan, and it is the monotonic
  definition of live: own `revoked_at` nil and own `expires_at`
  future. Revoking a token cascades to its minted descendants (see
  `RevokePat`), and a minted child never expires after its parent
  (the controller clamps it), so a severed child cannot hold a slot.
  """

  use Ash.Resource.Change

  alias FluxVale.Identity.PersonalAccessToken
  alias FluxVale.Identity.User

  require Ash.Query

  @max_live_derived_tokens 25
  @refusal_message "too many live minted tokens — revoke one first"

  @doc "The number of live minted tokens one user may hold."
  @spec max_live_derived_tokens() :: pos_integer()
  def max_live_derived_tokens, do: @max_live_derived_tokens

  @doc """
  Whether the errors carry this guard's own refusal: a global
  `InvalidChanges` with the cap's sentence. `MintPat` classifies
  exactly this error into `{:error, :too_many_live_tokens}`.
  """
  @spec refusal?([term()]) :: boolean()
  def refusal?(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidChanges{message: @refusal_message} -> true
      _other -> false
    end)
  end

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &enforce/1)
  end

  defp enforce(changeset) do
    metadata = Ash.Changeset.get_argument(changeset, :metadata) || %{}

    if is_binary(metadata["minted_parent_id"]) do
      refuse_at_cap(changeset)
    else
      changeset
    end
  end

  defp refuse_at_cap(changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)

    # Serialize per user: the count and the insert must be one
    # critical section, or concurrent mints both read below the cap.
    User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)

    # authorize?: false is an invariant count, not an authorization
    # question: the create policy already gated the caller, and the
    # cap must hold regardless of read-policy shape.
    if PersonalAccessToken.count_live_derived!(user_id, DateTime.utc_now()) >=
         @max_live_derived_tokens do
      Ash.Changeset.add_error(changeset, message: @refusal_message)
    else
      changeset
    end
  end
end
