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

# ---- #226 (k3d openapi EOF subclass): the young k3d apiserver sometimes
# drops kubectl's OpenAPI validation fetch (`failed to download openapi …
# EOF`) — runner-side, pre-test, twice observed. `kubectl apply` is
# idempotent, so a bounded retry is safe HERE ONLY: bootstrap phase,
# never the suite (a test must not silently rerun). Cap 3 attempts,
# 10s apart; the last attempt's full error stands on exhaustion (a real
# manifest failure fails loudly, ~20s slower). The "bootstrap-retry"
# marker keeps the flake rate measurable from logs; the ::warning::
# annotation renders on CI only.
bootstrap_retry_log() {
  echo "bootstrap-retry: $*" >&2
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "::warning::bootstrap-retry: $*" >&2
  fi
}
apply_with_retry() {
  attempt=1
  while true; do
    if kubectl apply "$@"; then
      return 0
    fi
    if [ "$attempt" -ge 3 ]; then
      echo "bootstrap-retry: kubectl apply failed on $attempt attempts — giving up (last error above)" >&2
      return 1
    fi
    bootstrap_retry_log "kubectl apply EOF-class failure (attempt $attempt/3) — retrying in 10s"
    attempt=$((attempt + 1))
    sleep 10
  done
}

# ---- cluster + registry (same config Tilt uses)
if ! k3d cluster list --no-headers 2>/dev/null | grep -q '^fluxvale '; then
  echo "==> creating k3d cluster + local registry"
  k3d cluster create --config deploy/local/k3d.yaml
else
  echo "==> k3d cluster exists"
fi
# The create path switches contexts itself; the reuse path doesn't —
# pin it, or a different current context takes every apply below.
kubectl config use-context k3d-fluxvale

# ---- dev image: build on the host, push to the k3d registry the nodes
# pull from (never docker.io). Fresh tag per run so a re-run always
# rolls a genuinely new image (IfNotPresent would cache a same-tag push).
tag="e2e-$(date +%s)"
# #210: cache the layers in the GHA cache on CI. Same image, tag, and
# push either way — the builder is buildx on both paths, and only the
# cache flags are CI-only, so CI and local can't drift. The gha cache
# needs the runner's runtime credentials plus a buildkit builder, both
# wired in the e2e job (ghaction-github-runtime + setup-buildx-action);
# build-push-action does that wiring internally for the release job, a
# manual buildx call does not. Own scope: the release build caches
# under the default scope — sharing it, the two would evict each other.
# ignore-error: a cache-service failure degrades to a cold build, it
# must not red the suite.
cache_flags=""
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  cache_flags="--cache-from type=gha,scope=e2e-dev --cache-to type=gha,scope=e2e-dev,mode=max,ignore-error=true"
fi
echo "==> building dev image ($base_image)"
# word-splitting is deliberate: an empty cache_flags means no flags
# shellcheck disable=SC2086
docker buildx build -f apps/platform/Dockerfile.dev --build-arg "BASE_IMAGE=$base_image" \
  $cache_flags --load \
  -t "$REGISTRY_HOST/fluxvale/platform-dev:$tag" apps/platform
docker push "$REGISTRY_HOST/fluxvale/platform-dev:$tag"

# ---- apply, in the Tiltfile's dependency order: namespace/RBAC, the
# two charts (CRDs land with them), then the CRs + app + route.
echo "==> applying namespace + RBAC"
apply_with_retry -f deploy/local/k8s/00-namespace.yaml -f deploy/local/k8s/01-platform-rbac.yaml

echo "==> charts: cnpg $cnpg_version, traefik $traefik_version"
helm upgrade --install cnpg cloudnative-pg --version "$cnpg_version" \
  --repo https://cloudnative-pg.github.io/charts --namespace cnpg-system --create-namespace --wait >/dev/null
helm upgrade --install traefik traefik --version "$traefik_version" \
  --repo https://traefik.github.io/charts --namespace traefik --create-namespace \
  -f deploy/local/traefik-values.yaml --wait >/dev/null

echo "==> CNPG Cluster CR + platform + IngressRoute"
apply_with_retry -f deploy/local/k8s/05-cnpg-cluster.yaml
apply_with_retry -f deploy/local/k8s/10-platform.yaml
# Both the app container AND the migrate initContainer carry the image
# (env is anchored, image isn't) — set both, or init pulls the
# registry-less manifest ref from docker.io. (Between apply and set the
# pod template nominally references docker.io — a brief first-run
# ImagePullBackOff window until set image lands; accepted, the rollout
# waits it out either way.)
kubectl -n "$NAMESPACE" set image deployment/fluxvale-platform \
  "platform=$REGISTRY_CLUSTER/fluxvale/platform-dev:$tag" \
  "migrate=$REGISTRY_CLUSTER/fluxvale/platform-dev:$tag" \
  "seed=$REGISTRY_CLUSTER/fluxvale/platform-dev:$tag"
apply_with_retry -f deploy/local/k8s/15-ingressroute.yaml

# #203 (ADR-0036) + #210 part 3: compress the idle-sweep knobs for the
# e2e suite — a real 1h idle isn't waitable in a test budget. The
# sweep CADENCE is now env-tunable (runtime.exs reads
# IDLE_SWEEP_CRONEXPR); every-minute is the floor Oban's cron allows,
# and it is safe for every leg (it only tightens when a sleeping
# instance's state lands, never causes one). The THRESHOLD default
# stays #209's 180s: the beacon's last-used marker is up to 30s stale
# under traffic, so a lower default risks sweeping a LIVE instance on
# the lifecycle legs mid-spec. The timers leg — no traffic by design
# — compresses further via its own env (ci.yml matrix:
# E2E_IDLE_SLEEP_AFTER_SECONDS=45 there). The nightly full-cadence
# run (e2e-nightly.yml) overrides both to the real 1h + */5 pair
# through the same envs. Dev stacks (tilt up) set neither — they keep
# the settled 1h + */5 defaults.
kubectl -n "$NAMESPACE" set env deployment/fluxvale-platform \
  "IDLE_SLEEP_AFTER_SECONDS=${E2E_IDLE_SLEEP_AFTER_SECONDS:-180}" \
  "IDLE_SWEEP_CRONEXPR=${E2E_SWEEP_CRONEXPR:-* * * * *}"

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

# #222: the backups spec assumes its bucket exists — configure an
# instance, run a backup, expect objects land. MinIO is the in-cluster
# stand-in for the owner's BYO S3 bucket (R2), so the bucket has to be
# there before any test runs, not created lazily mid-spec. AFTER the
# platform's own waits, deliberately: nothing in the platform's boot
# needs MinIO, and MinIO needs nothing from the platform (the bucket
# Job talks to the server directly) — while two cold Chainguard pulls
# before the rollout wait eat into its 600s budget (a rerun died that
# way: CNPG first boot + the extra pulls crossed the line).
echo "==> MinIO (e2e S3 proxy) + bucket"
# Two applies, on purpose. The first lands the server; the Job it also
# creates is thrown away by the delete below, because the restart that
# follows takes the server down under it.
# Why a restart at all: envFrom does not roll pods, so an edited fake
# password would leave the old key live in the server while the Job
# presents the new one ("Access Key Id ... does not exist").
# Why the Job is deleted first: its spec is immutable, and a finished pod
# keeps its status — otherwise the wait would pass on an earlier run.
# Data is a PVC and `mb --ignore-existing` is idempotent, so this loses
# nothing and leaves exactly one successful bucket-creation pod.
kubectl -n "$NAMESPACE" delete job minio-bucket --ignore-not-found
apply_with_retry -f deploy/local/k8s/12-minio.yaml
kubectl -n "$NAMESPACE" rollout restart deployment/minio
kubectl -n "$NAMESPACE" rollout status deployment/minio --timeout=180s
kubectl -n "$NAMESPACE" delete job minio-bucket --ignore-not-found
apply_with_retry -f deploy/local/k8s/12-minio.yaml
kubectl -n "$NAMESPACE" wait --for=condition=complete job/minio-bucket --timeout=180s

# ---- seeds (idempotent) + the suite's TestInbox PAT, in one exec into
# the live container (e2e_in_pod.exs boots the app with the endpoint
# listener off — the server process owns :4000 — and tags the token
# line so async log interleaving can't corrupt the contract)
echo "==> seeds + TestInbox PAT"
pat="$(
  kubectl -n "$NAMESPACE" exec -i deployment/fluxvale-platform -- \
    mix run --no-start priv/repo/e2e_in_pod.exs |
    sed -n 's/^E2E_PAT //p'
)"
test -n "$pat" || { echo "in-pod runner returned no PAT" >&2; exit 1; }

# rm first: `>` preserves an existing file's perms, and a rerun must
# not leave the fresh PAT in a previously-looser mode
umask 077
rm -f "$ENV_FILE"
printf 'E2E_TESTINBOX_TOKEN=%s\n' "$pat" >"$ENV_FILE"

# #222: the S3 target for the backups specs. The credentials are read
# back out of 12-minio.yaml's Secret rather than duplicated here — one
# literal, one place that can drift. go-template's base64decode keeps the
# decoding off the host's base64 flavour (macOS spells it -D).
minio_auth="$(
  kubectl -n "$NAMESPACE" get secret minio-root \
    -o go-template='MINIO_ROOT_USER={{index .data "MINIO_ROOT_USER" | base64decode}}{{"\n"}}MINIO_ROOT_PASSWORD={{index .data "MINIO_ROOT_PASSWORD" | base64decode}}'
)"
test -n "$minio_auth" || { echo "minio-root secret carries no credentials" >&2; exit 1; }
{
  printf 'MINIO_ENDPOINT=http://minio.%s.svc.cluster.local:9000\n' "$NAMESPACE"
  printf '%s\n' "$minio_auth"
  printf 'MINIO_BUCKET=fluxvale-e2e\n'
} >>"$ENV_FILE"

echo "==> stack ready: $APP_URL/health — credentials in $ENV_FILE"
echo "    set -a; source $ENV_FILE; set +a && cd apps/e2e && npx playwright test"
