defmodule FluxValeWeb.OrgNav do
  @moduledoc """
  The app chrome's org data (#276): resolves the actor's org memberships
  (org loaded) into `actor_orgs` for the `org_switcher`, plus the two
  facts the switcher's personal row needs — `personal_org_id` (the owned
  org, resolved by the canonical `Accounts.personal_org_for_user/2`) and
  `username` (its row label). Same on_mount shape as
  `FluxValeWeb.UserAuth`; wire it after UserAuth in the same on_mount
  lists — it reads the user UserAuth resolved.

  Data, not a gate: it never halts, redirects, or raises. No
  `current_user` (a miswiring — UserAuth runs first on every sanctioned
  site) assigns the empty list and nils — the switcher renders an empty
  panel. Zero orgs is unreachable for action-created users (signup's JIT
  provisioning members the creator); real for seeded/legacy rows, and
  the switcher degrades to an empty panel rather than a fake Personal
  row (#285 T6 — one row per membership, no chrome).
  """

  alias FluxVale.Accounts

  require Logger

  @doc """
  Resolves `current_user`'s orgs into `actor_orgs`, with the personal
  org id and row label. Never halts.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_orgs, _params, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        # Anonymous chrome (public layouts) — nothing to read, nothing
        # to label. The user struct is never touched.
        {:cont,
         Phoenix.Component.assign(socket,
           actor_orgs: [],
           personal_org_id: nil,
           username: nil
         )}

      user ->
        memberships = orgs(user)
        personal_org_id = personal_org_id(user)

        {:cont,
         Phoenix.Component.assign(socket,
           actor_orgs: ordered_orgs(memberships, personal_org_id),
           personal_org_id: personal_org_id,
           username: display_handle(user)
         )}
    end
  end

  defp orgs(user) do
    case Accounts.organizations_for_user(user.id, actor: user) do
      {:ok, memberships} ->
        memberships

      # Unreachable for a %User{} actor — the rows are scoped to
      # the actor's own memberships, which always pass the read
      # policy — and a DB failure is not simulatable under the
      # sandbox. Log + degrade: the switcher is chrome, not a gate.
      # coveralls-ignore-start
      {:error, reason} ->
        Logger.warning("OrgNav org lookup failed: #{inspect(reason)}")
        []
        # coveralls-ignore-stop
    end
  end

  # The personal org is whatever the canonical resolver says — the same
  # op `DashboardLive.wallet_summary/1` and the billing mount resolve
  # with, so the switcher's "Personal" label can never name a different
  # org than the one that gets billed (#285 T6 review: for a user owning
  # two orgs, a min-membership-id derivation and the canonical op name
  # different orgs; one extra query per mount buys correctness by
  # construction). Whether the canonical op's own tie-break for
  # two-owned-orgs users is the right one is the identity spec's (T7) —
  # out of scope here. The pinned row order below keys off this id.
  defp personal_org_id(user) do
    case Accounts.personal_org_for_user(user.id, actor: user) do
      {:ok, org} ->
        org.id

      :none ->
        nil

      # defensive: DB read failure, not simulatable under the
      # sandbox. Log + degrade: the switcher is chrome, not a gate.
      # coveralls-ignore-start
      {:error, reason} ->
        Logger.warning("OrgNav personal org lookup failed: #{inspect(reason)}")
        nil
        # coveralls-ignore-stop
    end
  end

  # One row per membership, the personal one first — #276's pinned
  # order, made deterministic (the DB doesn't promise a list order):
  # the rest ride uuid_v7 id order, i.e. creation order. Keyed off the
  # canonical personal_org_id above.
  defp ordered_orgs(memberships, personal_org_id) do
    {personal, rest} = Enum.split_with(memberships, &(&1.organization.id == personal_org_id))
    personal_first = Enum.sort_by(personal, & &1.id)
    rest_in_creation_order = Enum.sort_by(rest, & &1.id)

    Enum.concat(personal_first, rest_in_creation_order)
  end

  # The personal row's label. Rollout-window rows carry a NULL username
  # (the column is nullable until F1's contract migration) — degrade to
  # the address's local part, the PRIMARY one (#285 T4): reading the
  # frozen `users.email` mirror here showed the demoted signup address
  # after a SetPrimaryEmail. The nil-primary arm (old-pod straggler)
  # still lands on the mirror — see User.primary_email. The calc is
  # loaded by UserAuth.resolve_user/1 before this hook runs (the
  # sanctioned on_mount order — router-pinned); reading an unloaded
  # struct would raise, and that is the miswiring's crash to own.
  defp display_handle(user) do
    user.username || local_part(user.primary_email || user.email)
  end

  # Emails are CiStrings at the Ash boundary; downcast before String
  # owns it (the initial/1 posture in core_components).
  defp local_part(email) do
    address = to_string(email)
    [local_part | _domain] = String.split(address, "@", parts: 2)
    local_part
  end
end
