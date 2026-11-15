defmodule FluxVale.Accounts.Organization.EmptyOrgGuard do
  @moduledoc """
  The empty-org guard (#784): an organization is deletable only when it
  is a team org with nothing left to lose.

  The DB's `on_delete: :restrict` FKs are the backstop, but a raw FK
  failure is not a sentence a person can act on. This change runs
  before the destroy's teardown and turns the blockers into the
  platform's own words, in the order a caller can act on them.

  Blockers: a personal org (its owner's account surface), instances in
  any state, custom access domains (their Certificates need the
  removal operation), the private-access gateway, non-owner members,
  and a wallet (billing records are retained — `docs/data-deletion.md`).
  Owner co-members do not block: the owner policy already makes
  destroy an owner's call, and the teardown clears every membership.

  Not blockers: membership invites and PocketID custody events (DB
  cascade); custody and storage requests (they require an instance and
  cascade with it); feedback posts and votes (`on_delete: :nilify` —
  public board content outlives the org's attribution). The platform
  access-domain row is derived residue the teardown purges, not a
  blocker.

  The reads run `authorize?: false` (the system posture — the destroy
  policy already gated the caller) and inside the destroy's
  transaction. The org row is locked FOR UPDATE first — the
  LastOwnerGuard posture — so every blocker count observes committed
  state; a concurrent membership/instance/wallet write serializes on
  the org and loses to the teardown's FK.
  """

  use Ash.Resource.Change

  alias FluxVale.Accounts.Membership
  alias FluxVale.Accounts.Organization
  alias FluxVale.Billing.Wallet
  alias FluxVale.Infrastructure.AccessDomain
  alias FluxVale.Infrastructure.AccessGateway
  alias FluxVale.Infrastructure.Instance

  require Ash.Query

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      org = lock_org(changeset.data.id)

      case blocking_reason(org) do
        nil -> changeset
        message -> Ash.Changeset.add_error(changeset, field: :id, message: message)
      end
    end)
  end

  # The org row is the serialization point: every blocker carries an FK
  # to it, so a concurrent lifecycle write takes a key-share lock that
  # conflicts with this FOR UPDATE until the destroy commits.
  defp lock_org(org_id) do
    Organization
    |> Ash.Query.filter(id == ^org_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(authorize?: false)
  end

  defp blocking_reason(%{personal_owner_id: id}) when not is_nil(id) do
    "This is a personal organization — its owner's account surface — and cannot be deleted."
  end

  defp blocking_reason(org) do
    instances = count(Instance, org.id)
    domains = custom_domains(org.id)
    gateways = count(AccessGateway, org.id)
    members = other_members(org.id)

    cond do
      instances > 0 ->
        count_message("instance", "Delete", instances)

      domains > 0 ->
        count_message("custom domain", "Remove", domains)

      gateways > 0 ->
        "This organization still has a private-access gateway. Opt out of it first."

      members > 0 ->
        "This organization still has members who are not owners. Remove them first."

      wallet?(org.id) ->
        "This organization has billing history and is retained. Organizations that have held a wallet cannot be deleted."

      true ->
        nil
    end
  end

  defp count(resource, org_id) do
    resource
    |> Ash.Query.filter(organization_id == ^org_id)
    |> Ash.count!(authorize?: false)
  end

  defp custom_domains(org_id) do
    AccessDomain
    |> Ash.Query.filter(organization_id == ^org_id and kind == :custom)
    |> Ash.count!(authorize?: false)
  end

  defp other_members(org_id) do
    Membership
    |> Ash.Query.filter(organization_id == ^org_id and role != :owner)
    |> Ash.count!(authorize?: false)
  end

  defp wallet?(org_id) do
    match?({:ok, _wallet}, Wallet.get_by_organization(org_id, authorize?: false))
  end

  defp count_message("instance", verb, 1),
    do: "This organization still has 1 instance. #{verb} it first."

  defp count_message("instance", verb, count),
    do: "This organization still has #{count} instances. #{verb} them first."

  defp count_message("custom domain", verb, 1),
    do: "This organization still has 1 custom domain. #{verb} it first."

  defp count_message("custom domain", verb, count),
    do: "This organization still has #{count} custom domains. #{verb} them first."
end
