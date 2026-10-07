# Runs on `mix setup` (dev) — the same promotable seed the release runs
# at bring-up (`bin/seed` → `FluxVale.Release.seed/0` → `Seeds.seed/0`,
# #98). local_seeds.exs stays dev/local-only (the `local` Cluster row).

FluxVale.Seeds.seed()
