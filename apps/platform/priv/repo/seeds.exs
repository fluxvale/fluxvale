# Runs on `mix setup` (dev) — the dev bootstrap seed. Creates one platform
# admin so the admin-gated surfaces (TestInbox #22, Ops CRUD #25/#26) have a
# real actor. No AccessRule rows ship: environments gate themselves through
# the AshAdmin CRUD at bring-up (settled on #26; ADR-0023 Am. 6's
# empty-then-close).
#
# The creates run with authorize?: false: bootstrap — there is no actor to
# authorize before the first admin exists (same posture as the User#create
# policy comment).

admin_email = "admin@fluxvale.com"

case FluxVale.Identity.User.get_by_email(admin_email, authorize?: false) do
  {:ok, _existing} ->
    :ok

  {:error, _not_found} ->
    FluxVale.Identity.User.create!(admin_email, %{platform_role: :admin}, authorize?: false)
end

# Catalog seed (#70): idempotent — safe on every mix setup.
FluxVale.Seeds.seed_catalog!()

# Local cluster row (#72): nil kubeconfig_ref = in-cluster sentinel
# (ADR-0006 Am. 2). Idempotent — safe on every mix setup.
FluxVale.Seeds.seed_local_cluster!()
