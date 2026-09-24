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
