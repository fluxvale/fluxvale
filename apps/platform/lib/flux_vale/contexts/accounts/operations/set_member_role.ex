defmodule FluxVale.Accounts.Operations.SetMemberRole do
  @moduledoc """
  An owner sets a membership's org role (slice 5 of #408): promote a
  member to owner, demote an owner to member. The action's owner policy
  is the gate; this seam names it and owns the guard copy: the
  last-owner refusal surfaces as `{:error, :last_owner}` and
  `guard_message/0` is the plain sentence the UI renders (one home —
  the resource's field-scoped message stays the API-facing truth).

  Ownership transfer composes from this primitive and a demote or
  RemoveMember — no separate transfer operation ships (#408 slice 5).
  """

  alias FluxVale.Accounts.Membership
  alias FluxVale.Identity.User

  @guard_message "This organization must keep at least one owner. Promote another member first."

  @spec call(User.t(), Membership.t(), :owner | :member) ::
          {:ok, Membership.t()} | {:error, :last_owner | term()}
  def call(%User{} = actor, %Membership{} = membership, role) do
    case Membership.set_role(membership, %{role: role}, actor: actor) do
      {:ok, _updated} = ok ->
        ok

      {:error, %Ash.Error.Invalid{errors: errors}} = refusal ->
        if Membership.LastOwnerGuard.refusal?(errors), do: {:error, :last_owner}, else: refusal

      {:error, _refused} = refusal ->
        refusal
    end
  end

  @doc "The plain sentence for the last-owner refusal — the Members tab's flash copy"
  @spec guard_message :: String.t()
  def guard_message, do: @guard_message
end
