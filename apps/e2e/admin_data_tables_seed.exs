# Dev-only capture setup for the admin data-table gallery (#501).
# RESETS its own prior rows (address prefix datatable-capture-), then
# builds one SHAPE-DETERMINISTIC state: 26 invitations for the capture
# admin — a full first page of 25 at the default size, page two
# carrying exactly one row, so the boundary shots (next enabled, next
# exhausted) and the size switch (50 folds two pages into one) are the
# same every run. The invited-at stamps tie at second precision, so
# the id tiebreak (uuid v7, creation order) makes every sort state
# deterministic too: newest-created first by default, oldest first
# under Invited ascending.
#
# A second admin (a real account, its JIT personal org irrelevant
# here) holds no invitations: the honest empty state's subject.
#
# Prints the two session tokens the capture script needs.
#
# Run from apps/platform: mix run ../e2e/admin_data_tables_seed.exs

alias FluxVale.Identity
alias FluxVale.Identity.User
alias FluxVale.Identity.UserEmail
alias FluxVale.Repo

import Ecto.Query

# Reset this script's own prior rows (the dev DB keeps everything
# else). The capture users' JIT personal orgs carry memberships, so the
# reset walks the FK chain down (the gateways capture seed's stance):
# the personal orgs and their wallets first, the memberships, then the
# account rows. The users table carries no address (#287) — the emails
# mirror is keyed by address, the accounts by username (create!
# derives it from the address local part).
user_ids = Repo.all(from(u in "users", where: like(u.username, "datatable-%"), select: u.id))

org_ids =
  Repo.all(
    from(m in "memberships",
      where: m.user_id in ^user_ids,
      select: m.organization_id
    )
  )

wallet_ids =
  Repo.all(from(w in "billing_wallets", where: w.organization_id in ^org_ids, select: w.id))

{_, nil} = Repo.delete_all(from(e in "billing_ledger_entries", where: e.wallet_id in ^wallet_ids))

{_, nil} = Repo.delete_all(from(w in "billing_wallets", where: w.id in ^wallet_ids))

{_, nil} = Repo.delete_all(from(m in "memberships", where: m.user_id in ^user_ids))

{_, nil} = Repo.delete_all(from(o in "organizations", where: o.id in ^org_ids))

{_, nil} =
  Repo.delete_all(from(ue in "user_emails", where: ue.user_id in ^user_ids))

{_, nil} = Repo.delete_all(from(u in "users", where: u.id in ^user_ids))

# The capture admin (get-or-create keeps the script safe on a fresh
# dev DB).
admin =
  case User.get_by_email("datatable-capture@fluxvale.test", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User.create!("datatable-capture@fluxvale.test", %{platform_role: :admin}, authorize?: false)
  end

# 26 invitations through the real action (nil actor + authorize?:
# false, the seeds posture; the deliver discards — dev-capture
# tooling sends no mail). The invited-at stamps are backdated to
# distinct days, so the sorted column shows visibly different values
# and a sort's reorder reads as a reorder, not a reshuffle.
now = DateTime.utc_now()

for i <- 1..26 do
  address =
    "datatable-capture-invite-#{String.pad_leading(Integer.to_string(i), 2, "0")}-#{System.unique_integer([:positive])}@quillsystems.test"

  {:ok, user, _raw} =
    Identity.invite_user(
      nil,
      address,
      fn _to, _url -> {:ok, :discarded} end,
      authorize?: false
    )

  backdated = DateTime.add(now, -i, :day)

  {1, _} =
    Repo.update_all(
      from(u in "users", where: u.id == ^Ecto.UUID.dump!(user.id)),
      set: [invited_at: backdated]
    )
end

# The empty admin: a real account, no invitations (the honest empty's
# subject).
empty_admin =
  case User.get_by_email("datatable-empty-capture@fluxvale.test", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User.create!("datatable-empty-capture@fluxvale.test", %{platform_role: :admin},
        authorize?: false
      )
  end

# FV_PHASE=empty strips every invite (the honest-empty shots need a
# state with no invitation rows at all — the people list is
# platform-wide, so a different admin sees the same rows); the
# default gallery phase builds the full state. The empty phase runs
# FIRST, the gallery phase after it re-seeds.
phase = System.get_env("FV_PHASE", "gallery")

if phase == "empty" do
  invite_user_ids =
    Repo.all(
      from(u in "users",
        join: ue in "user_emails",
        on: ue.user_id == u.id,
        where: like(ue.address, "datatable-capture-invite-%"),
        select: u.id
      )
    )

  {_, nil} = Repo.delete_all(from(ue in "user_emails", where: ue.user_id in ^invite_user_ids))
  {_, nil} = Repo.delete_all(from(u in "users", where: u.id in ^invite_user_ids))

  IO.puts("PHASE=empty: every invite stripped, the list is honestly empty")
end

{:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)
{:ok, empty_token, _} = AshAuthentication.Jwt.token_for_user(empty_admin)

# The width-probe pass rides the SEEDED admin (local seeds' "admin-2"):
# a platform admin with org memberships, so every adopting surface can
# render a populated table (the gateway and instance reads are
# member-scoped; the wallet read rides the platform-admin arm). One id
# per detail surface comes with it.
seeded_id =
  case Repo.one(from(u in "users", where: u.username == "admin-2", select: u.id)) do
    nil ->
      created = User.create!("admin-2@fluxvale.test", %{platform_role: :admin}, authorize?: false)
      created.id

    user_id ->
      user_id
  end

seeded = Ash.get!(User, seeded_id, authorize?: false)

seeded_wallet =
  case Repo.all(
         from(w in "billing_wallets",
           order_by: [desc: w.created_at],
           limit: 1,
           select: w.id
         )
       ) do
    [wallet_id] -> Ecto.UUID.cast!(wallet_id)
    [] -> nil
  end

seeded_org =
  case Repo.one(
         from(m in "memberships",
           where: m.user_id == ^seeded_id,
           limit: 1,
           select: m.organization_id
         )
       ) do
    nil -> nil
    org_id -> Ecto.UUID.cast!(org_id)
  end

seeded_gateway =
  case Repo.one(
         from(g in "access_gateways",
           join: m in "memberships",
           on: m.organization_id == g.organization_id,
           where: m.user_id == ^seeded_id,
           limit: 1,
           select: g.id
         )
       ) do
    nil -> nil
    gateway_id -> Ecto.UUID.cast!(gateway_id)
  end

{:ok, seeded_token, _} = AshAuthentication.Jwt.token_for_user(seeded)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_TOKEN_EMPTY=#{empty_token}")
IO.puts("FV_TOKEN_SEEDED=#{seeded_token}")
IO.puts("FV_WALLET=#{seeded_wallet}")
IO.puts("FV_ORG=#{seeded_org}")
IO.puts("FV_GATEWAY=#{seeded_gateway}")
