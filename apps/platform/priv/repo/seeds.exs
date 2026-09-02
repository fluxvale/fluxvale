# Runs on `mix setup` (dev) — the dev bootstrap seed. Creates one platform
# admin so the admin-gated surfaces (TestInbox #22, Ops CRUD #25/#26) have a
# real actor. Staging/prod seeds — access rules per ADR-0023 — arrive with
# #26, env-switched.
#
# The create runs with authorize?: false: bootstrap — there is no actor to
# authorize before the first admin exists (same posture as the User#create
# policy comment).

admin_email = "admin@fluxvale.com"

case FluxVale.Identity.User.get_by_email(admin_email, authorize?: false) do
  {:ok, _existing} ->
    :ok

  {:error, _not_found} ->
    FluxVale.Identity.User.create!(admin_email, %{platform_role: :admin}, authorize?: false)
end
