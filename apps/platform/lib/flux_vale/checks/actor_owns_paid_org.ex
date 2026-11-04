defmodule FluxVale.Checks.ActorOwnsPaidOrg do
  @moduledoc """
  The feedback-board write gate (ADR-0026 §2/§3, fluxvale/fluxvale#412):
  a write names an org and passes only when the actor HOLDS AN OWNER
  MEMBERSHIP of that org AND the org is past the paid gate. The paid arm
  is `ActorOrgHasPaid.org_paid?/1` verbatim — a $1+ purchase or the
  operator's paywall waiver; welcome credits never qualify. Mere members
  of a paid org get nothing: the vote slot (and the post) belong to the
  org, and casting them is the owner's call.

  Arms (any one passes; the admin test runs first, then the owner test
  gates both remaining arms):

  - **Admin** — `ActorIsPlatformAdmin` passes everything.
  - **Owner + paid** — the steady-state gate: an `:owner` membership of
    the org in play and `ActorOrgHasPaid.org_paid?/1`.
  - **Launch allowlist** (ADR-0026 §3, the :feedback-purpose
    AccessRule rows) — the paid test's launch-time alternative: until
    the first purchase exists the board opens to the invite cohort, an
    allowlisted actor passing for an org they own WITHOUT the paid
    test. The payment is what the launch arm substitutes; ownership is
    not. The arm resolves the actor's PRIMARY email (`User.primary_email`)
    and fails closed when it cannot, or when the actor is absent —
    anonymous gets nothing.

  The org in play follows the org-in-play discipline (see
  ActorOrgHasPaid): a CREATE answers the org the write NAMES — the
  action's `organization_id` argument, falling back to the attribute —
  and when the write names nothing, the actor's personal org (the
  SetActorDefaults pattern, so check and change agree on the same row).
  Update/destroy re-read the ROW from the database: an in-process
  caller controls the changeset's in-memory struct, and the gate must
  not be caller-controlled. Any org that cannot resolve fails closed,
  as does any non-changeset subject.
  """

  use Ash.Policy.SimpleCheck

  alias FluxVale.Accounts
  alias FluxVale.Checks.ActorIsOrganizationOwner
  alias FluxVale.Checks.ActorIsPlatformAdmin
  alias FluxVale.Checks.ActorOrgHasPaid
  alias FluxVale.Ops.AccessRules

  @impl Ash.Policy.Check
  def describe(_opts),
    do:
      "the actor owns the org in play and it has paid (or the launch allowlist / an admin passes)"

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, _opts) do
    case org_in_play(context.subject, actor) do
      {:ok, org_id} -> board_write_allowed?(actor, org_id)
      # Org unresolvable (nothing named, no personal org, reload
      # failure, non-changeset subject): fail closed.
      :error -> false
    end
  end

  @doc """
  The plug/LiveView-facing predicate — same answer as the policy check:
  may this actor write the board for this org? An absent actor or an
  unresolved org fails closed.
  """
  @spec board_write_allowed?(map() | nil, Ash.UUID.t() | nil) :: boolean()
  def board_write_allowed?(actor, org_id) when is_map(actor) and not is_nil(org_id) do
    ActorIsPlatformAdmin.platform_admin?(actor) or
      owner_gate(actor, org_id)
  end

  def board_write_allowed?(_actor, _org_id), do: false

  # Owner of the org in play, past the paid gate — or, under the launch
  # arm, launch-allowlisted (the paid test waived, the ownership test
  # not). org_paid?/1 short-circuits before the allowlist read for
  # payers; the cohort's path pays one email lookup + one rules read.
  defp owner_gate(actor, org_id) do
    if ActorIsOrganizationOwner.owner?(actor.id, org_id) do
      ActorOrgHasPaid.org_paid?(org_id) or allowlisted?(actor)
    else
      false
    end
  end

  # A create answers the org the write NAMES — argument first, then the
  # attribute (both intake shapes, the ActorOrgHasPaid posture) — and
  # defaults to the actor's personal org when nothing is named, the
  # same resolution SetActorDefaults/SetCastDefaults perform for the
  # row. Never passes a caller-controlled attribute for non-creates:
  # loaded rows are re-read fresh below.
  defp org_in_play(%Ash.Changeset{action_type: :create} = changeset, actor) do
    named =
      Ash.Changeset.get_argument(changeset, :organization_id) ||
        Ash.Changeset.get_attribute(changeset, :organization_id)

    if is_nil(named) do
      actor_org_id(actor)
    else
      {:ok, named}
    end
  end

  # Atomic changesets carry this placeholder — Ash.reload would raise
  # on it, and no org resolves from it: fail closed.
  defp org_in_play(%Ash.Changeset{data: %Ash.Changeset.OriginalDataNotAvailable{}}, _actor),
    do: :error

  # Update/destroy: the ROW's org, freshly read — the in-memory struct
  # is caller-controlled, the gate is not (the ActorOrgHasPaid stance).
  defp org_in_play(%Ash.Changeset{data: data}, _actor) do
    case Ash.reload(data, authorize?: false) do
      {:ok, %{organization_id: org_id}} when not is_nil(org_id) -> {:ok, org_id}
      _unresolved -> :error
    end
  end

  defp org_in_play(_subject, _actor), do: :error

  defp actor_org_id(actor) when is_map(actor) do
    case Accounts.personal_org_for_user(actor.id, authorize?: false) do
      {:ok, org} -> {:ok, org.id}
      _none_or_error -> :error
    end
  end

  defp actor_org_id(_other), do: :error

  # The launch arm reads the actor's PRIMARY email — the Identity
  # domain's verified-primary calculation — through an authorize-free
  # load: the check IS the authorization (the ActorIsOrganizationOwner
  # posture). No primary, no load: fail closed.
  defp allowlisted?(actor) do
    case Ash.load(actor, :primary_email, authorize?: false) do
      {:ok, %{primary_email: nil}} ->
        false

      {:ok, %{primary_email: email}} ->
        AccessRules.allowed?(:feedback, email)

      # coveralls-ignore-start - defensive: the actor read failing is a
      # DB outage, not simulatable under the sandbox (DBConnection
      # reconnects — the repo's cluster-level stance)
      {:error, _load_failure} ->
        false

        # coveralls-ignore-stop
    end
  end
end
