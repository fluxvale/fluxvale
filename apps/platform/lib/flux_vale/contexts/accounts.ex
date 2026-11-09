defmodule FluxVale.Accounts do
  @moduledoc """
  Accounts: organizations, memberships, and their invitations
  (ADR-0030) — the ownership, billing, and abuse boundary for everything
  a customer's resources attach to. Every user gets a personal org at
  signup (`provision_personal_org/1`, creator = owner); users reach orgs
  through memberships, which is what policies resolve against.

  The Organization list route (GET /api/v1/organizations, #362 T6a)
  rides AshJsonApi.Domain (#360): the resource-level json_api block
  joins the machine API through AshJsonApiRouter — routes are
  contract-tested, never inferred.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshJsonApi.Domain, AshPaperTrail.Domain]

  alias FluxVale.Accounts.Operations.LeaveOrganization
  alias FluxVale.Accounts.Operations.RemoveMember
  alias FluxVale.Accounts.Operations.SetMemberRole

  # The paper-trail seam (#645, ADR-0048): versioned resources' Version
  # modules join the domain here so codegen migrates them and reads see
  # them. The console registry excludes them by name — the audit trail
  # surfaces in its own section, not as raw tables.
  paper_trail do
    include_versions?(true)
  end

  resources do
    resource(FluxVale.Accounts.Membership)
    resource(FluxVale.Accounts.MembershipInvite)
    resource(FluxVale.Accounts.Organization)
  end

  # Operations are verb-named modules under operations/ (see
  # apps/platform/AGENTS.md); the domain stays the public seam
  defdelegate provision_personal_org(user),
    to: FluxVale.Accounts.Operations.ProvisionPersonalOrg,
    as: :call

  defdelegate personal_org_for_user(user_id, opts \\ []),
    to: FluxVale.Accounts.Operations.PersonalOrgForUser,
    as: :call

  defdelegate organizations_for_user(user_id, opts \\ []),
    to: FluxVale.Accounts.Operations.OrganizationsForUser,
    as: :call

  # The orgs a user OWNS (the feedback islands' picker, #412 T5) —
  # distinct from organizations_for_user above: mere membership is not
  # the write gate, ownership is.
  defdelegate owned_orgs_for_user(user_id, opts \\ []),
    to: FluxVale.Accounts.Operations.OwnedOrgsForUser,
    as: :call

  defdelegate create_organization(user, params),
    to: FluxVale.Accounts.Operations.CreateOrganization,
    as: :call

  # The invitation flow (slice 4 of #408)
  defdelegate invite_member(owner, org, email),
    to: FluxVale.Accounts.Operations.InviteMember,
    as: :call

  defdelegate revoke_invite(owner, invite),
    to: FluxVale.Accounts.Operations.RevokeInvite,
    as: :call

  defdelegate resolve_invite(token), to: FluxVale.Accounts.Operations.ResolveInvite, as: :call

  defdelegate accept_invite(token, user), to: FluxVale.Accounts.Operations.AcceptInvite, as: :call

  defdelegate decline_invite(token), to: FluxVale.Accounts.Operations.DeclineInvite, as: :call

  # Member lifecycle (slice 5 of #408): owners set roles and remove
  # members, a member leaves on their own — the last-owner guard rides
  # all three. Ownership transfer composes from these primitives.
  defdelegate set_member_role(actor, membership, role),
    to: FluxVale.Accounts.Operations.SetMemberRole,
    as: :call

  defdelegate remove_member(actor, membership),
    to: FluxVale.Accounts.Operations.RemoveMember,
    as: :call

  defdelegate leave_organization(actor, membership),
    to: FluxVale.Accounts.Operations.LeaveOrganization,
    as: :call

  @doc """
  The last-owner guard sentence for a lifecycle seam — the Members
  tab's flash copy. Each operation owns its own wording; the domain
  only routes the seam's name to it.
  """
  @spec guard_message(:set_member_role | :remove_member | :leave_organization) :: String.t()
  def guard_message(:set_member_role), do: SetMemberRole.guard_message()
  def guard_message(:remove_member), do: RemoveMember.guard_message()
  def guard_message(:leave_organization), do: LeaveOrganization.guard_message()

  @doc """
  The welcome-credit grant (integer cents) a fresh personal org receives
  (defined once on the operation).
  """
  defdelegate welcome_grant_cents,
    to: FluxVale.Accounts.Operations.ProvisionPersonalOrg
end
