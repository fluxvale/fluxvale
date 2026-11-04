defmodule FluxVale.Checks.ActorBelowOrgCreateCap do
  @moduledoc """
  Policy check: the actor holds `:owner` memberships in fewer than
  @org_create_cap orgs — the per-user org-creation cap (#408).

  A SOFT product guard, not a security boundary: the count runs before
  the write with no lock, so two concurrent creates can both pass the
  count and land. Accepted — the cap bounds runaway volume, not single
  creates. Revisit trigger: if the cap must become exact, take an
  advisory lock keyed on the user (a transactional count alone still
  races — READ COMMITTED never sees the concurrent uncommitted row).

  Only `FluxVale.Identity.User` actors count — any other actor shape
  fails closed. Structural duck-typing (the ActorIsOrganizationOwner
  shape) would let a bare `%{id: …}` map count zero orgs and pass, so
  this check pins the struct.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts.Membership
  alias FluxVale.Identity.User

  require Ash.Query

  # The per-user cap on owned organizations (#408) — one home; the
  # policy message reads it, callers may too if a surface ever needs it.
  @org_create_cap 10

  @impl Ash.Policy.Check
  def describe(_opts), do: "actor owns fewer than #{@org_create_cap} organizations"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, _context, _opts), do: below_cap?(actor)

  @doc """
  The plug/LiveView-facing predicate — same answer as the policy check.
  """
  @spec below_cap?(term()) :: boolean()
  def below_cap?(%User{id: user_id}), do: owned_org_count(user_id) < @org_create_cap
  def below_cap?(_actor), do: false

  # authorize?: false — the check IS the authorization (the
  # ActorIsOrganizationOwner posture).
  defp owned_org_count(user_id) do
    Membership
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(user_id == ^user_id and role == :owner)
    |> Ash.count!(authorize?: false)
  end
end
