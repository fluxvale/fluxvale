# Dev-only capture setup for the Audit section (#645, A2-S4). Builds a
# small deterministic slice of trail on the dev DB through the REAL
# actions (every write versions, so the trail fills itself):
#
# - Three feature flags by the admin actor: one created then updated
#   (the changes-details capture), one created then DESTROYED (the
#   honest destroy evidence on the index), one written with no actor
#   (the System tombstone on camera).
# - Four curated tags (the resource-filtered capture).
#
# Prints the admin session token and the flag id the capture script
# needs. Run from apps/platform: mix run ../e2e/admin_audit_seed.exs

alias FluxVale.Feedback.Tag
alias FluxVale.Identity.User
alias FluxVale.Ops.FeatureFlag

admin =
  case User.get_by_email("admin@fluxvale.com", authorize?: false) do
    {:ok, existing} ->
      existing

    {:error, _not_found} ->
      User
      |> Ash.Changeset.for_create(:create, %{email: "admin@fluxvale.com", platform_role: :admin})
      |> Ash.create!(authorize?: false)
  end

suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
n = System.unique_integer([:positive])

# 1. The updated flag: its chain is create + update, so the changes
#    details block shows real deltas. The create interface takes the
#    key as its argument (define(:create, args: [:key])).
flag_updated =
  FeatureFlag.create!("audit_seed_updates_#{suffix}", %{enabled: true}, actor: admin)

flag_updated =
  flag_updated
  |> Ash.Changeset.for_update(
    :update,
    %{description: "Seeded for the audit console captures", rollout_percentage: 25},
    actor: admin
  )
  |> Ash.update!()

# 2. The destroyed flag: the trail keeps its final row (no source
#    reference, the doctrine's destroy evidence).
flag_destroyed = FeatureFlag.create!("audit_seed_retired_#{suffix}", %{}, actor: admin)

flag_destroyed
|> Ash.Changeset.for_destroy(:destroy, %{}, actor: admin)
|> Ash.destroy!()

# 3. The system write: no actor rode this create, the honest System
#    tombstone.
FeatureFlag.create!("audit_seed_system_#{suffix}", %{}, authorize?: false)

# 4. The curated vocabulary: rows for the resource-filtered capture.
for i <- 1..4 do
  Tag.create!(%{name: "audit-capture-#{suffix}-#{i}"}, actor: admin)
end

{:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(admin)

IO.puts("FV_TOKEN=#{token}")
IO.puts("FV_FLAG_DETAIL=#{flag_updated.id}")
