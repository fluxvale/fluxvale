# Kubereq is Mimic-copied before ExUnit starts: resource-module tests stub
# its API calls (v1's canonical pattern — shape assertions, no cluster)
Mimic.copy(Kubereq)
Mimic.copy(FluxVale.Identity)
# Instance lifecycle (#73): ops tests stub the resource modules and the
# kubeconfig resolution; :k8s-tagged integration tests stay excluded
# unless run explicitly against the local Tilt stack
# (`mix test --only k8s`, see instance_integration_test.exs).
Mimic.copy(FluxVale.Clients.K8s)
Mimic.copy(FluxVale.Clients.K8s.Resources.Namespace)
Mimic.copy(FluxVale.Clients.K8s.Resources.Deployment)
Mimic.copy(FluxVale.Clients.K8s.Resources.Service)
Mimic.copy(FluxVale.Clients.K8s.Resources.Ingress)
Mimic.copy(FluxVale.Clients.K8s.Resources.Secret)
Mimic.copy(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim)
Mimic.copy(FluxVale.Clients.K8s.Resources.ResourceQuota)
Mimic.copy(FluxVale.Clients.K8s.Resources.NetworkPolicy)
Mimic.copy(FluxVale.Clients.K8s.Resources.RoleBinding)

ExUnit.start(exclude: [k8s: true])
Ecto.Adapters.SQL.Sandbox.mode(FluxVale.Repo, :manual)
