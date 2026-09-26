#!/usr/bin/env bash
# E2E bootstrap (#75, ADR-0020 Am. 4): the supported non-interactive
# path to a running local stack — the SAME sources the Tiltfile uses
# (k3d config, pinned charts, deploy/local manifests, dev image), no
# Tilt involved (Am. 1/3: Tilt's non-interactive modes are unreliable).
# CI and local re-runs drive this one script, so the two can't drift.
#
# Needs on PATH: docker, k3d, kubectl, helm, curl (mise provides the
# middle three: `mise install`). Idempotent: an existing cluster,
# charts, and manifests are updated in place.
#
# Exits 0 when https://app.fluxvale.lvh.me/health is ok, seeds are in,
# and apps/e2e/.e2e-env holds a fresh admin PAT. Then:
#   set -a; source apps/e2e/.e2e-env; set +a
#   cd apps/e2e && npx playwright test
set -euo pipefail

cd "$(dirname "$0")/.."

REGISTRY_HOST="127.0.0.1:5000"
REGISTRY_CLUSTER="fluxvale-registry:5000"
NAMESPACE="fluxvale-dev"
APP_URL="https://app.fluxvale.lvh.me"
ENV_FILE="apps/e2e/.e2e-env"

# ---- single source of truth: chart + base-image pins come out of the
# Tiltfile (with its mise.toml assertions). A missing pattern means the
# Tiltfile changed shape — update this grep, don't fork the pin.
cnpg_version="$(sed -n 's/.*install cnpg cloudnative-pg --version \([0-9.]*\).*/\1/p' Tiltfile)"
traefik_version="$(sed -n 's/.*install traefik traefik --version \([0-9.]*\).*/\1/p' Tiltfile)"
base_image="$(sed -n "s/^BASE_IMAGE = '\([^']*\)'.*/\1/p" Tiltfile)"
for pin in "$cnpg_version" "$traefik_version" "$base_image"; do
  test -n "$pin" || { echo "could not parse a pin out of Tiltfile — did it change shape?" >&2; exit 1; }
done

for tool in docker k3d kubectl helm curl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

# ---- cluster + registry (same config Tilt uses)
if ! k3d cluster list --no-headers 2>/dev/null | grep -q '^fluxvale '; then
  echo "==> creating k3d cluster + local registry"
  k3d cluster create --config deploy/local/k3d.yaml
else
  echo "==> k3d cluster exists"
fi

# ---- dev image: build on the host, push to the k3d registry the nodes
# pull from (never docker.io). Fresh tag per run so a re-run always
# rolls a genuinely new image (IfNotPresent would cache a same-tag push).
tag="e2e-$(date +%s)"
echo "==> building dev image ($base_image)"
docker build -f apps/platform/Dockerfile.dev --build-arg "BASE_IMAGE=$base_image" \
  -t "$REGISTRY_HOST/fluxvale/platform-dev:$tag" apps/platform
docker push "$REGISTRY_HOST/fluxvale/platform-dev:$tag"

# ---- apply, in the Tiltfile's dependency order: namespace/RBAC, the
# two charts (CRDs land with them), then the CRs + app + route.
echo "==> applying namespace + RBAC"
kubectl apply -f deploy/local/k8s/00-namespace.yaml -f deploy/local/k8s/01-platform-rbac.yaml

echo "==> charts: cnpg $cnpg_version, traefik $traefik_version"
helm upgrade --install cnpg cloudnative-pg --version "$cnpg_version" \
  --repo https://cloudnative-pg.github.io/charts --namespace cnpg-system --create-namespace --wait >/dev/null
helm upgrade --install traefik traefik --version "$traefik_version" \
  --repo https://traefik.github.io/charts --namespace traefik --create-namespace \
  -f deploy/local/traefik-values.yaml --wait >/dev/null

echo "==> CNPG Cluster CR + platform + IngressRoute"
kubectl apply -f deploy/local/k8s/05-cnpg-cluster.yaml
kubectl apply -f deploy/local/k8s/10-platform.yaml
# Both the app container AND the migrate initContainer carry the image
# (env is anchored, image isn't) — set both, or init pulls the
# registry-less manifest ref from docker.io. (Between apply and set the
# pod template nominally references docker.io — a brief first-run
# ImagePullBackOff window until set image lands; accepted, the rollout
# waits it out either way.)
kubectl -n "$NAMESPACE" set image deployment/fluxvale-platform \
  "platform=$REGISTRY_CLUSTER/fluxvale/platform-dev:$tag" \
  "migrate=$REGISTRY_CLUSTER/fluxvale/platform-dev:$tag"
kubectl apply -f deploy/local/k8s/15-ingressroute.yaml

# The init container crash-loops until CNPG hands out the DB secret —
# by design (never half-migrated); the rollout just waits through it.
echo "==> waiting for the platform rollout (init migrations gate boot)"
kubectl -n "$NAMESPACE" rollout status deployment/fluxvale-platform --timeout=600s

echo "==> waiting for $APP_URL/health"
deadline=$((SECONDS + 300))
until curl -skf "$APP_URL/health" >/dev/null; do
  test "$SECONDS" -lt "$deadline" || { echo "app never became healthy" >&2; exit 1; }
  sleep 5
done

# ---- seeds (idempotent) + the suite's TestInbox PAT, in one exec into
# the live container (e2e_in_pod.exs boots the app with the endpoint
# listener off — the server process owns :4000 — and wraps the token in
# sentinels so async log lines can't steal the contract)
echo "==> seeds + TestInbox PAT"
pat="$(
  kubectl -n "$NAMESPACE" exec -i deployment/fluxvale-platform -- \
    mix run --no-start priv/repo/e2e_in_pod.exs |
    sed -n '/^E2E_PAT_BEGIN$/,/^E2E_PAT_END$/p' | sed '1d;$d'
)"
test -n "$pat" || { echo "in-pod runner returned no PAT" >&2; exit 1; }

umask 077
printf 'E2E_TESTINBOX_TOKEN=%s\n' "$pat" >"$ENV_FILE"

echo "==> stack ready: $APP_URL/health — credentials in $ENV_FILE"
echo "    set -a; source $ENV_FILE; set +a && cd apps/e2e && npx playwright test"
