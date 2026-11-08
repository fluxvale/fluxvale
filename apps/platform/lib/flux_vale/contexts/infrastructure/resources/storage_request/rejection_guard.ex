defmodule FluxVale.Infrastructure.StorageRequest.RejectionGuard do
  @moduledoc """
  The operator rejection (#250, ADR-0046 §3): an open request becomes
  `rejected`, with required feedback the member sees verbatim.

  Rejection is terminal and serves two shapes: the ordinary decline of
  a `requested` row, and the escape hatch for an `approved` request the
  infrastructure can never apply (capacity cannot be attached, the
  instance is gone). Either way the one-open-request index releases and
  the member is never left waiting on an approval the box cannot honor.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.StorageRequest

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    %StorageRequest{} = request = changeset.data
    reason = Ash.Changeset.get_attribute(changeset, :rejection_reason)

    cond do
      request.status not in [:requested, :approved] ->
        Ash.Changeset.add_error(
          changeset,
          "only an open storage request can be rejected"
        )

      reason in [nil, ""] ->
        Ash.Changeset.add_error(changeset, "rejection feedback is required")

      is_nil(context.actor) ->
        Ash.Changeset.add_error(changeset, "an operator must reject the request")

      true ->
        reject(changeset, context.actor)
    end
  end

  defp reject(changeset, actor) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, :rejected)
    |> Ash.Changeset.force_change_attribute(:decided_by_user_id, actor.id)
    |> Ash.Changeset.force_change_attribute(:decided_at, DateTime.utc_now())
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (audit attributes)
  def atomic?, do: false
end
