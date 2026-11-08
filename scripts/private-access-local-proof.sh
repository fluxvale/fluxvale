#!/usr/bin/env bash
# Local halves of the private-access exit proof (#273, ADR-0039 §6).
#
# Proves, on this box and without a tailnet:
#   Part A — the serve table: a sleeping attached instance's serve-config
#            Secret targets the platform's /internal/access pair; after
#            the instance lands :running and the config is regenerated,
#            the same port targets http://app.<ns>.svc.cluster.local:80.
#   Part B — the live endpoint: GET /internal/access/<gateway>/<instance>
#            returns the waking page, wakes the instance, and an unknown
#            pair gets the byte-identical 404.
#
# What it cannot prove: a gateway pod on a real tailnet, the .ts.net
# certificate, or a request from a tailnet device. That is the staging
# runbook (docs/plans/273-private-access-staging-proof.md).
#
# Prereq in a fresh worktree: cd apps/platform && mix content.sync (the
# app boot loads priv/content; the proof's `mix run` needs it too).
#
# Usage: scripts/private-access-local-proof.sh
# Env:   FV273_PROOF_SHOTS   screenshot output dir (default: docs/screenshots/fv273-local-proof)
#        FV273_PROOF_STATE   state json (default: /tmp/opencode/fv273-private-access-proof-state.json)
#        FV273_PROOF_KUBECONFIG  temp kubeconfig (default: /tmp/opencode/...kubeconfig)
#        FV273_PROOF_BASE_URL    override the endpoint (a host `mix phx.server`,
#                                e.g. http://127.0.0.1:4000) when the k3d pod is
#                                a stale image without the /internal/access route
#
# The script refuses to continue if the endpoint has no wake route (the
# "not found" probe below), so a stale image is a loud wall, not a fake pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIX_DIR="$ROOT/apps/platform"
E2E_DIR="$ROOT/apps/e2e"
STATE="${FV273_PROOF_STATE:-/tmp/opencode/fv273-private-access-proof-state.json}"
KUBECONFIG_PATH="${FV273_PROOF_KUBECONFIG:-/tmp/opencode/fv273-private-access-proof.kubeconfig}"
SHOTS="${FV273_PROOF_SHOTS:-$ROOT/docs/screenshots/fv273-local-proof}"
CTX="k3d-fluxvale"
EVIDENCE="$(mktemp -d /tmp/opencode/fv273-proof-evidence.XXXXXX)"

FAILURES=0
PF_PID=""
CLEANED=0
BASE_URL=""
CURL=(curl -sk -m 20)
WAKE_URL=""
# 1 = the endpoint runs inside the k3d pod (in-cluster SA auth works);
# 0 = a host-run `mix phx.server` (the temp kubeconfig row must stay set).
INPOD=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
step() { printf '\n== %s ==\n' "$*"; }

run_mix() {
  local env_extra="${FV273_MIX_ENV_EXTRA:-}"
  (cd "$MIX_DIR" && env $env_extra MIX_ENV=dev mix run "$ROOT/scripts/private-access-local-proof.exs" "$@")
}

kc() { kubectl --context "$CTX" "$@"; }

# ---------------------------------------------------------------------------
# cleanup — runs on every exit, including a failed proof
# ---------------------------------------------------------------------------

fallback_delete_objects() {
  [[ -f "$STATE" ]] || return 0
  local gateway_id ns short object
  gateway_id="$(jq -r '.gateway_id // empty' "$STATE")"
  ns="$(jq -r '.namespace // empty' "$STATE")"

  if [[ -n "$gateway_id" ]]; then
    short="$(printf '%s' "$gateway_id" | tr -d '-' | rev | cut -c1-10 | rev)"
    for object in \
      "deployment/gateway-$short" \
      "secret/serve-config-$short" \
      "secret/credential-$short" \
      "secret/api-credential-$short" \
      "pvc/state-$short"; do
      kc -n fluxvale-access delete "$object" --ignore-not-found >/dev/null 2>&1 || true
    done
    kc -n fluxvale-access delete deployment,secret,pvc -l "fluxvale.io/gateway=$gateway_id" \
      --ignore-not-found >/dev/null 2>&1 || true
  fi

  if [[ -n "$ns" ]]; then
    kc delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  kc delete namespace -l "app.kubernetes.io/part-of=fv273-private-access-proof" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

wait_namespace_gone() {
  [[ -f "$STATE" ]] || return 0
  local ns
  ns="$(jq -r '.namespace // empty' "$STATE")"
  [[ -n "$ns" ]] || return 0
  for _ in $(seq 1 60); do
    if ! kc get namespace "$ns" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

do_cleanup() {
  [[ "$CLEANED" -eq 1 ]] && return
  CLEANED=1

  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi

  if [[ -f "$STATE" ]]; then
    step "cleanup"
    local cleanup_ok=1

    if ! run_mix cleanup "$STATE" "$KUBECONFIG_PATH"; then
      cleanup_ok=0
      # The provider's teardown is the normal path. Its fallback deletes
      # the named objects directly, then a forced cleanup removes the
      # row; FV273_FORCE_CLEANUP is what authorises the hard delete.
      fallback_delete_objects
      if FV273_MIX_ENV_EXTRA="FV273_FORCE_CLEANUP=1" run_mix cleanup "$STATE" "$KUBECONFIG_PATH"; then
        cleanup_ok=1
      fi
    fi

    FV273_MIX_ENV_EXTRA="FV273_FORCE_CLEANUP=1" run_mix restore_cluster "$STATE" "$KUBECONFIG_PATH" ||
      cleanup_ok=0

    if wait_namespace_gone; then
      pass "proof namespace absent from the cluster"
    else
      fail "proof namespace still present after 60s"
      cleanup_ok=0
    fi

    if [[ "$cleanup_ok" -eq 1 ]]; then
      rm -f "$STATE"
      rm -f "$KUBECONFIG_PATH"
      pass "cleanup complete; Cluster row restored; temp kubeconfig removed"
    else
      fail "cleanup incomplete; state kept at $STATE for inspection"
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

trap do_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

preflight() {
  step "preflight"

  if kc config get-contexts -o name | grep -qx "$CTX"; then
    pass "kubectl context $CTX exists (current: $(kubectl config current-context 2>/dev/null || echo unknown))"
  else
    fail "kubectl context $CTX missing"
    return 1
  fi

  if kc -n fluxvale-access get role fluxvale-platform-access >/dev/null 2>&1; then
    pass "Role fluxvale-platform-access exists in fluxvale-access"
  else
    fail "Role fluxvale-platform-access missing — apply deploy/local/k8s/02-access-fleet.yaml"
  fi

  if kc -n fluxvale-access get resourcequota access-quota >/dev/null 2>&1; then
    pass "ResourceQuota access-quota exists in fluxvale-access"
  else
    fail "ResourceQuota access-quota missing — apply deploy/local/k8s/02-access-fleet.yaml"
  fi

  local resource verb
  for resource in deployments secrets persistentvolumeclaims; do
    for verb in create get patch delete; do
      # PVCs deliberately have no get verb in the provider's Role.
      if [[ "$resource" == "persistentvolumeclaims" && "$verb" == "get" ]]; then
        continue
      fi
      if kc auth can-i "$verb" "$resource" -n fluxvale-access \
        --as=system:serviceaccount:fluxvale-dev:fluxvale-platform >/dev/null 2>&1; then
        pass "RBAC: $verb $resource in fluxvale-access"
      else
        fail "RBAC: $verb $resource in fluxvale-access denied"
      fi
    done
  done

  if [[ -n "${FV273_PROOF_BASE_URL:-}" ]]; then
    BASE_URL="${FV273_PROOF_BASE_URL%/}"
    if [[ "$BASE_URL" == https://* ]]; then
      CURL=(curl -sk -m 20 --resolve app.fluxvale.lvh.me:443:127.0.0.1)
    else
      CURL=(curl -s -m 20)
    fi
    body="$("${CURL[@]}" "$BASE_URL/health" 2>/dev/null)"
    if printf '%s' "$body" | grep -q '"status":"ok"'; then
      pass "platform reachable at the configured endpoint ($BASE_URL/health; $body)"
    else
      fail "configured platform endpoint $BASE_URL/health is not healthy"
      return 1
    fi
  elif body="$(curl -sk -m 10 --resolve app.fluxvale.lvh.me:443:127.0.0.1 \
    https://app.fluxvale.lvh.me/health 2>/dev/null)" &&
    printf '%s' "$body" | grep -q '"status":"ok"'; then
    BASE_URL="https://app.fluxvale.lvh.me"
    CURL=(curl -sk -m 20 --resolve app.fluxvale.lvh.me:443:127.0.0.1)
    INPOD=1
    pass "platform reachable at https://app.fluxvale.lvh.me/health ($body)"
  else
    local port=$((4400 + RANDOM % 200))
    kc -n fluxvale-dev port-forward svc/fluxvale-platform "$port:4000" \
      >"$EVIDENCE/port-forward.log" 2>&1 &
    PF_PID=$!
    for _ in $(seq 1 30); do
      if body="$(curl -s -m 2 "http://127.0.0.1:$port/health" 2>/dev/null)" &&
        printf '%s' "$body" | grep -q '"status":"ok"'; then
        break
      fi
      sleep 1
    done
    if printf '%s' "$body" | grep -q '"status":"ok"'; then
      BASE_URL="http://127.0.0.1:$port"
      CURL=(curl -s -m 20)
      INPOD=1
      pass "platform reachable via port-forward at $BASE_URL/health ($body)"
    else
      fail "platform not reachable at https://app.fluxvale.lvh.me/health or via port-forward"
      return 1
    fi
  fi

  kubectl --context "$CTX" config view --raw --minify --context "$CTX" >"$KUBECONFIG_PATH"
  chmod 600 "$KUBECONFIG_PATH"
  if grep -q '^[[:space:]]*server:' "$KUBECONFIG_PATH"; then
    pass "temp kubeconfig written from kubectl config view --raw ($KUBECONFIG_PATH)"
  else
    fail "temp kubeconfig has no server"
    return 1
  fi

  if [[ -d "$E2E_DIR/node_modules/@playwright/test" ]]; then
    pass "Playwright available in apps/e2e"
  else
    fail "Playwright missing — run (cd apps/e2e && npm install && npx playwright install chromium)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------

capture() {
  local scheme="$1"
  run_mix reset "$STATE" "$KUBECONFIG_PATH" || return 1
  (cd "$E2E_DIR" && node access_wake_local_proof.mjs "$WAKE_URL" "$SHOTS" "$scheme")
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  step "private-access local proof"
  echo "state:      $STATE"
  echo "kubeconfig: $KUBECONFIG_PATH"
  echo "evidence:   $EVIDENCE"

  preflight || {
    echo "WALL  preflight failed; nothing seeded. See FAIL lines above."
    exit 1
  }

  mkdir -p "$SHOTS"

  step "seed"
  if ! run_mix seed "$STATE" "$KUBECONFIG_PATH"; then
    echo "WALL  seed failed: (cd apps/platform && MIX_ENV=dev mix run ../../scripts/private-access-local-proof.exs seed \"$STATE\" \"$KUBECONFIG_PATH\")"
    exit 1
  fi
  pass "seed completed"

  local gw inst ns
  gw="$(jq -r '.gateway_id' "$STATE")"
  inst="$(jq -r '.instance_id' "$STATE")"
  ns="$(jq -r '.namespace' "$STATE")"
  WAKE_URL="$BASE_URL/internal/access/$gw/$inst"

  echo "gateway:   $gw"
  echo "instance:  $inst"
  echo "namespace: $ns"
  echo "wake URL:  $WAKE_URL"

  # A stale local platform image answers /internal/access with Phoenix's
  # NoRoute page, not the controller's identical "not found". Catch that
  # before spending the captures and Part B on the wrong endpoint.
  local probe_pair route_body
  probe_pair="$(cat /proc/sys/kernel/random/uuid)"
  route_body="$("${CURL[@]}" -H 'Accept: text/html' \
    "$BASE_URL/internal/access/$probe_pair/$probe_pair")"
  if [[ "$route_body" == "not found" ]]; then
    pass "wake route is live on $BASE_URL (unknown pair → 'not found')"
  else
    fail "wake route is absent/stale on $BASE_URL (body starts: $(printf '%s' "$route_body" | head -c 80))"
    echo "WALL  the endpoint has no /internal/access route. Start a current dev server"
    echo "      (cd apps/platform && MIX_ENV=dev mix phx.server) and rerun with"
    echo "      FV273_PROOF_BASE_URL=http://127.0.0.1:4000. The k3d pod may be a stale image."
    exit 1
  fi

  step "Part A — serve table"
  if run_mix part_a "$STATE" "$KUBECONFIG_PATH"; then
    pass "Part A checks completed"
  else
    fail "Part A failed"
  fi

  step "captures — local wake page (light and dark)"
  if capture light; then
    pass "captured light wake page from $WAKE_URL"
  else
    fail "light capture failed"
  fi
  if capture dark; then
    pass "captured dark wake page from $WAKE_URL"
  else
    fail "dark capture failed"
  fi

  # Put the instance back to sleep for Part B. An in-pod endpoint needs
  # the Cluster row restored (it uses its service account); a host-run
  # server keeps the temp kubeconfig row so it can scale the Deployment.
  step "Part B — live endpoint"
  if run_mix reset "$STATE" "$KUBECONFIG_PATH"; then
    if [[ "$INPOD" == "1" ]] && ! run_mix restore_cluster "$STATE" "$KUBECONFIG_PATH"; then
      fail "could not restore the Cluster row for the in-pod endpoint"
    else
      pass "instance sleeping; endpoint ready ($([[ "$INPOD" == "1" ]] && echo in-pod || echo host-run))"
    fi
  else
    fail "could not prepare Part B"
  fi

  local http_code
  http_code="$("${CURL[@]}" -H 'Accept: text/html' \
    -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/142 Safari/537.36' \
    -o "$EVIDENCE/wake-page.html" -w '%{http_code}' "$WAKE_URL")"

  if [[ "$http_code" == "200" ]]; then
    pass "GET $WAKE_URL → 200"
  else
    fail "GET $WAKE_URL → $http_code (wanted 200)"
  fi

  if grep -q 'data-testid="access-waking-page"' "$EVIDENCE/wake-page.html" &&
    grep -q 'Waking' "$EVIDENCE/wake-page.html"; then
    pass "response is the waking page (data-testid=access-waking-page, 'Waking … up')"
  else
    fail "response is not the waking page; head: $(head -c 200 "$EVIDENCE/wake-page.html")"
  fi

  if run_mix verify_wake "$STATE" "$KUBECONFIG_PATH"; then
    pass "wake landed (status left :sleeping or Deployment replicas=1)"
  else
    fail "wake did not land"
  fi

  local pair_a pair_b code_a code_b
  pair_a="$(cat /proc/sys/kernel/random/uuid)"
  pair_b="$(cat /proc/sys/kernel/random/uuid)"

  code_a="$("${CURL[@]}" -H 'Accept: text/html' \
    -o "$EVIDENCE/notfound-a.txt" -w '%{http_code}' \
    "$BASE_URL/internal/access/$pair_a/$pair_a")"
  code_b="$("${CURL[@]}" -H 'Accept: text/html' \
    -o "$EVIDENCE/notfound-b.txt" -w '%{http_code}' \
    "$BASE_URL/internal/access/$pair_b/$pair_b")"

  if [[ "$code_a" == "404" && "$code_b" == "404" ]]; then
    pass "two random pairs → 404 each"
  else
    fail "random pairs → $code_a and $code_b (wanted 404 each)"
  fi

  if cmp -s "$EVIDENCE/notfound-a.txt" "$EVIDENCE/notfound-b.txt"; then
    pass "random-pair 404 bodies are byte-identical ($(sha256sum "$EVIDENCE/notfound-a.txt" | cut -c1-16)…)"
  else
    fail "random-pair 404 bodies differ"
  fi

  if [[ "$(cat "$EVIDENCE/notfound-a.txt")" == "not found" ]]; then
    pass "404 body is exactly 'not found'"
  else
    fail "404 body is $(cat "$EVIDENCE/notfound-a.txt")"
  fi

  if ! cmp -s "$EVIDENCE/wake-page.html" "$EVIDENCE/notfound-a.txt"; then
    pass "waking page and 404 are different responses"
  else
    fail "waking page and 404 are identical"
  fi

  step "evidence"
  echo "wake page:  $EVIDENCE/wake-page.html"
  echo "404 A/B:    $EVIDENCE/notfound-a.txt $EVIDENCE/notfound-b.txt"
  echo "shots:      $SHOTS"

  do_cleanup

  local residual
  residual="$(kc -n fluxvale-access get deploy,secret,pvc -o name 2>/dev/null |
    grep -E '(gateway|serve-config|credential|state)-' || true)"
  if [[ -z "$residual" ]]; then
    pass "no gateway objects remain in fluxvale-access"
  else
    fail "residual gateway objects in fluxvale-access: $(printf '%s' "$residual" | tr '\n' ' ')"
  fi

  if [[ "$FAILURES" -gt 0 ]]; then
    printf '\nFAIL  local proof: %s check(s) failed\n' "$FAILURES"
    exit 1
  fi

  printf '\nPASS  local proof: all checks passed\n'
  printf 'NOTE  the real-tailnet leg is NOT proven here; see docs/plans/273-private-access-staging-proof.md\n'
}

main "$@"
