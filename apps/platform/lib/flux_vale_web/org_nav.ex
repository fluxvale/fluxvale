defmodule FluxValeWeb.OrgNav do
  @moduledoc """
  The app chrome's org data (#276): resolves the actor's org memberships
  (org loaded) into `actor_orgs` for the `org_switcher`, plus the two
  facts the switcher's personal row needs — `personal_org_id` (the owned
  org, the `:owner` membership) and `username` (its row label). Same
  on_mount shape as `FluxValeWeb.UserAuth`; wire it after UserAuth in the
  same on_mount lists — it reads the user UserAuth resolved.

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
        personal_org_id = personal_org_id(memberships)

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

  # The personal org is the user's earliest `:owner` membership —
  # signup's JIT provisioning creates it in-transaction, before any
  # later org join, and uuid_v7 ids sort chronologically, so the minimum
  # id is the personal org. `PersonalOrgForUser` resolves the same
  # notion with an unordered `limit 1`; this derivation adds the
  # ordering the loaded list can't promise, still from memberships
  # already in hand — no second query.
  defp personal_org_id(memberships) do
    owners = Enum.filter(memberships, &(&1.role == :owner))
    first = Enum.min_by(owners, & &1.id, fn -> nil end)

    first && first.organization.id
  end

  # One row per membership, the personal one first — #276's pinned
  # order, made deterministic (the DB doesn't promise a list order):
  # the rest ride uuid_v7 id order, i.e. creation order.
  defp ordered_orgs(memberships, personal_org_id) do
    {personal, rest} = Enum.split_with(memberships, &(&1.organization.id == personal_org_id))
    personal_first = Enum.sort_by(personal, & &1.id)
    rest_in_creation_order = Enum.sort_by(rest, & &1.id)

    Enum.concat(personal_first, rest_in_creation_order)
  end

  # The personal row's label. Rollout-window rows carry a NULL username
  # (the column is nullable until F1's contract migration) — degrade to
  # the signup email's local part. F1 (#287) drops users.email: the
  # fallback then reads the primary address from user_emails.
  defp display_handle(user) do
    user.username || local_part(user.email)
  end

  # Emails are CiStrings at the Ash boundary; downcast before String
  # owns it (the initial/1 posture in core_components).
  defp local_part(email) do
    address = to_string(email)
    [local_part | _domain] = String.split(address, "@", parts: 2)
    local_part
  end
end
