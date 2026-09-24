# Kubereq is Mimic-copied before ExUnit starts: resource-module tests stub
# its API calls (v1's canonical pattern — shape assertions, no cluster)
Mimic.copy(Kubereq)
Mimic.copy(FluxVale.Identity)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(FluxVale.Repo, :manual)
