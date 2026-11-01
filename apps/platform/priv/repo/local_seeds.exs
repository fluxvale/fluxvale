# Local-environment bring-up seed (#72): creates the `local` Cluster row
# (nil kubeconfig_ref = the in-cluster sentinel, ADR-0006 Am. 2).
#
# Deliberately separate from seeds.exs: this script is dev/local-only and
# never gains a prod caller. In staging/production the cluster row is
# operator bring-up data — admin-entered through AshAdmin (ADR-0027), the
# same never-seeded posture as AccessRule — because there the name and
# repoint history are operator decisions (ADR-0006's migration rung), not
# a well-known constant.
#
# Idempotent — safe on every run.

FluxVale.Seeds.seed_local_cluster!()

# Dev-only unlock for private access's paid-once gate: no payment
# gateway exists in dev, so a wallet that has never paid could never
# enable or resume a gateway locally (the welcome credit deliberately
# doesn't count). One $5 purchase credit on the seed admin's personal
# org, idempotent by the ledger's idempotency key — re-runs replay to
# the same entry, never a double credit.
#
# NEVER move this into priv/repo/seeds.exs: that script runs at prod
# bring-up (`bin/seed`), and a production wallet is funded by real
# payments only.

admin = FluxVale.Identity.User.get_by_email!("admin@fluxvale.com", authorize?: false)

{:ok, org} = FluxVale.Accounts.personal_org_for_user(admin.id, authorize?: false)

{:ok, _entry} =
  FluxVale.Billing.credit_wallet(org, 500, idempotency_key: "local-seeds:paid-unlock")
