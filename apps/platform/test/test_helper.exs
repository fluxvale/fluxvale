# Kubereq is Mimic-copied before ExUnit starts: resource-module tests stub
# its API calls (v1's canonical pattern — shape assertions, no cluster)
Mimic.copy(Kubereq)
Mimic.copy(FluxVale.Identity)
Mimic.copy(FluxVale.Billing)
# HitPay adapter tests stub Req the same way (v1's Dodo pattern: the
# client translates HTTP/network failures; tests assert the atoms)
Mimic.copy(Req)
# Instance lifecycle (#73): ops tests stub the resource modules and the
# kubeconfig resolution; :k8s-tagged integration tests stay excluded
# unless run explicitly against the local Tilt stack
# (`mix test --only k8s`, see instance_integration_test.exs).
Mimic.copy(FluxVale.Clients.K8s)
Mimic.copy(FluxVale.Clients.K8s.Resources.Namespace)
Mimic.copy(FluxVale.Clients.K8s.Resources.Deployment)
Mimic.copy(FluxVale.Clients.K8s.Resources.Service)
Mimic.copy(FluxVale.Clients.K8s.Resources.Ingress)
Mimic.copy(FluxVale.Clients.K8s.Resources.Middleware)
Mimic.copy(FluxVale.Clients.K8s.Resources.Secret)
Mimic.copy(FluxVale.Clients.K8s.Resources.PersistentVolumeClaim)
Mimic.copy(FluxVale.Clients.K8s.Resources.ResourceQuota)
Mimic.copy(FluxVale.Clients.K8s.Resources.NetworkPolicy)
Mimic.copy(FluxVale.Clients.K8s.Resources.RoleBinding)
Mimic.copy(FluxVale.Clients.K8s.Resources.BackupJob)
Mimic.copy(FluxVale.Clients.K8s.Resources.RestoreJob)
# The restore operation's status funnel: tests force the :restoring write
# to fail (the row-settling arm) without a hand-edited state machine.
Mimic.copy(FluxVale.Infrastructure.Operations.InstanceK8s)
# #238: the deploy's RBAC-propagation wait probes SelfSubjectAccessReview
Mimic.copy(FluxVale.Clients.K8s.SelfAccessReview)
# #268 (ADR-0039): the access provider boundary. Operation tests stub the
# provider (and keep the cluster out of the DB suite); provider tests stub
# the K8s resource modules beneath it.
Mimic.copy(FluxVale.Infrastructure.AccessProviders.Tailscale)
# The attach race (P3-3): a test must be able to make `create_route` lose
# the unique index while another attempt's row is committed.
Mimic.copy(FluxVale.Infrastructure.AccessRoute)
Mimic.copy(FluxVale.Infrastructure.AccessProvider)

ExUnit.start(exclude: [k8s: true])
Ecto.Adapters.SQL.Sandbox.mode(FluxVale.Repo, :manual)
