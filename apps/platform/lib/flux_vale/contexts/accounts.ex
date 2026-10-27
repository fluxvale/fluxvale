defmodule FluxVale.Accounts do
  @moduledoc """
  Accounts: organizations and memberships (ADR-0030) — the ownership,
  billing, and abuse boundary for everything a customer's resources attach
  to. Every user gets a personal org at signup (`provision_personal_org/1`,
  creator = owner); users reach orgs through memberships, which is what
  policies resolve against.

  Deliberately no JSON:API exposure — a backend model until a consumer
  needs one (v1 stance).
  """

  use Ash.Domain, otp_app: :flux_vale

  resources do
    resource FluxVale.Accounts.Membership
    resource FluxVale.Accounts.Organization
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
end
