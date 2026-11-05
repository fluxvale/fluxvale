defmodule FluxVale.Accounts.Operations.RemoveMember do
  @moduledoc """
  An owner removes another member from the org (slice 5 of #408). The
  action's owner policy is the gate; this seam names it and owns the
  guard copy: the last-owner refusal surfaces as `{:error, :last_owner}`
  and `guard_message/0` is the plain sentence the UI renders (one home
  — the resource's field-scoped message stays the API-facing truth).

  Removing yourself is NOT this seam — `LeaveOrganization` is (clearer
  policy, clearer copy); the action refuses self-removal outright.
  """

  alias FluxVale.Accounts.Membership
  alias FluxVale.Identity.User

  @guard_message "This organization must keep at least one owner, so this member cannot be removed yet."

  # Ash destroy actions answer :ok — the row is gone, there is no
  # record to hand back.
  @spec call(User.t(), Membership.t()) :: :ok | {:error, :last_owner | term()}
  def call(%User{} = actor, %Membership{} = membership) do
    case Membership.remove_member(membership, actor: actor) do
      :ok ->
        :ok

      {:error, %Ash.Error.Invalid{errors: errors}} = refusal ->
        if last_owner_refusal?(errors), do: {:error, :last_owner}, else: refusal

      {:error, _refused} = refusal ->
        refusal
    end
  end

  @doc "The plain sentence for the last-owner refusal — the Members tab's flash copy"
  @spec guard_message :: String.t()
  def guard_message, do: @guard_message

  # The guard's field-scoped message, read from the resource (one
  # constant, no fork — the ActorIsOrganizationOwner delegation stance).
  # Any other Invalid error (a cast failure on :role, say) fails the
  # first arm and bubbles as the raw refusal.
  defp last_owner_refusal?(errors) do
    Enum.any?(errors, fn error ->
      match?(%Ash.Error.Changes.InvalidAttribute{field: :role}, error) and
        error.message == Membership.LastOwnerGuard.refusal_message()
    end)
  end
end
