# Private-access edge

**Internal** operator runbook. The access edge serves a private instance only through its
organization's gateway
([ADR-0040](../adr/00040-strong-private-access-and-custom-domains.md) Am. 6): each access
route matches the hostname **and** the pairing gateway pod's address.

## What is where

- **Route:** `IngressRoute access-<id>` in the instance namespace, rule
  `Host(..) && ClientIP(<pod IP>/32)`, label `fluxvale.io/gateway`.
- **Address:** the gateway's newest running pod in the access namespace.
- **Refresher:** the platform job `ReconcileAccessAdmission`, every minute.

## Verify (read-only)

Every access route carries the check — prints nothing when healthy:

```sh
kubectl get ingressroute -A -o json | jq -r '.items[] | select(.spec.entryPoints|index("access"))
  | select(.spec.routes[0].match|test("ClientIP")|not) | .metadata.namespace+"/"+.metadata.name'
```

The admitted address is the gateway's current pod — compare, per gateway id:

```sh
kubectl get ingressroute -A -o json | jq -r '.items[] | select(.spec.entryPoints|index("access"))
  | "\(.metadata.labels["fluxvale.io/gateway"])\t\(.spec.routes[0].match)"' | sort -u
kubectl get pods -n <access namespace> -l app.kubernetes.io/name=access-gateway -o json \
  | jq -r '.items[] | "\(.metadata.labels["fluxvale.io/gateway"])\t\(.status.podIP)"'
```

Each time a gateway's address changes, the platform log carries one
`Access edge: gateway … admitted source is now …` line for it. A pass where nothing moved
logs nothing, and the Oban job `ReconcileAccessAdmission` (queue `access_admission`, every
minute) is the record that it ran.

## A private hostname answers 404 on the owner's tailnet

- Within a minute of a gateway pod being replaced: expected. Wait.
- While the gateway is suspended (scaled to zero): expected — the panel says "paused".
- Longer: run both checks above. A different address means the refresher is not converging.
  Read the platform log (`Access edge: gateway … address read failed`), the Oban job
  `ReconcileAccessAdmission`, and the platform's `pods: list` grant in the access namespace.
- `has no running pod` in the log while the pod is up: compare the pod's
  `fluxvale.io/gateway` label with the row.

## Rollback

Revert the PR ([ADR-0014](../adr/00014-rollback-protocol.md)). The previous build drops the
clause the next time an arm is applied and the refresher stops. Routes then answer any
gateway again — the state this check exists to end.
