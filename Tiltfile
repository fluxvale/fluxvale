# Tiltfile — local production-parity stack (ADR-0020).
#
#   k3d cluster create --config deploy/local/k3d.yaml   # once (or after delete)
#   tilt up                                              # from the repo root
#
# Parity ledger vs prod: k8s object shape, CNPG operator + service DNS,
# in-cluster ServiceAccount, Traefik routing (chart in both envs — nothing
# k3s-bundled), namespace convention, init-container migrations, env-var
# shape. Deliberately differs (ADR-0020): dev image runs `mix phx.server`
# (prod runs the OTP release — that delta is what staging verifies),
# self-signed TLS, no Cloudflare edge, no backups.
#
# At M4 the fleet repo is born with the real base manifests and the local
# overlay pattern moves there (ADR-0007) — this file then shrinks to the
# dev-loop conveniences.

allow_k8s_contexts('k3d-fluxvale')

# Dev images push to the k3d-managed local registry (created by k3d.yaml);
# nodes pull from it — nothing ever touches docker.io.
default_registry('127.0.0.1:5000')

# ---- toolchain: mise.toml is the single source of truth -------------------
# hexpm image tags append rebuild suffixes (e.g. erlang-28.5.0.6), so the
# full tag is pinned HERE — with an assertion that it still matches
# mise.toml's BEAM pins. A mise bump that outgrows the image fails `tilt up`
# immediately with this message instead of building with a stale toolchain.
BASE_IMAGE = 'hexpm/elixir:1.20.4-erlang-28.5.0.6-alpine-3.24.1'

mise_lines = str(read_file('mise.toml')).split('\n')

def mise_pin(key):
    for line in mise_lines:
        if line.startswith(key + ' = "'):
            return str(line).split('"')[1]
    fail('mise.toml: no %s pin found' % key)

mise_elixir = mise_pin('elixir').split('-')[0]  # 1.20.4 (strips -otp-28)
mise_otp = mise_pin('erlang')                  # 28.5

if not BASE_IMAGE.find('%s-erlang' % mise_elixir) >= 0:
    fail('BASE_IMAGE %r does not match mise.toml elixir %r — bump BASE_IMAGE alongside mise' % (BASE_IMAGE, mise_elixir))
if not BASE_IMAGE.find('erlang-%s' % mise_otp) >= 0:
    fail('BASE_IMAGE %r does not match mise.toml erlang %r — bump BASE_IMAGE alongside mise' % (BASE_IMAGE, mise_otp))

# ---- platform app ----------------------------------------------------------
docker_build(
    'fluxvale/platform-dev',
    context='apps/platform',
    dockerfile='apps/platform/Dockerfile.dev',
    build_args={'BASE_IMAGE': BASE_IMAGE},
    # ADR-0020: edit → synced reload in single-digit seconds. Phoenix's code
    # reloader recompiles in-container on the next request; deps stay baked
    # in the image (never synced).
    live_update=[
        fall_back_on(paths=['apps/platform/mix.lock']),
        sync('apps/platform/lib', '/app/lib'),
        sync('apps/platform/priv', '/app/priv'),
        sync('apps/platform/assets', '/app/assets'),
        sync('apps/platform/config', '/app/config'),
    ],
)

k8s_yaml(['deploy/local/k8s/00-namespace.yaml', 'deploy/local/k8s/10-platform.yaml'])

# The IngressRoute CRD ships with the Traefik chart — same static-parse
# problem as the Cluster CR, so it applies at runtime, ordered after traefik.
k8s_custom_deploy(
    'ingressroute',
    apply_cmd='kubectl apply -f deploy/local/k8s/15-ingressroute.yaml -o yaml',
    delete_cmd='kubectl delete -f deploy/local/k8s/15-ingressroute.yaml --ignore-not-found',
    image_deps=[],
    deps=['deploy/local/k8s/15-ingressroute.yaml'],
)

# The CNPG Cluster CR needs the operator's CRD installed first — k8s_yaml
# would statically parse (and drop) it before that, so it applies at
# runtime via custom deploy, ordered after the operator.
k8s_custom_deploy(
    'fluxvale-cnpg',
    apply_cmd='kubectl apply -f deploy/local/k8s/05-cnpg-cluster.yaml -o yaml',
    delete_cmd='kubectl delete -f deploy/local/k8s/05-cnpg-cluster.yaml --ignore-not-found',
    image_deps=[],
    deps=['deploy/local/k8s/05-cnpg-cluster.yaml'],
)

# ---- charts (both environments, per ADR-0020 — nothing k3s-bundled) -------
# k8s_custom_deploy + pinned chart versions: deterministic, no Tilt
# extension dependency. `--wait` makes the apply_cmd succeed only when the
# chart is actually up (CNPG operator ready to reconcile the Cluster CR).
k8s_custom_deploy(
    'cnpg',
    apply_cmd='helm upgrade --install cnpg cloudnative-pg --version 0.29.0 --repo https://cloudnative-pg.github.io/charts --namespace cnpg-system --create-namespace --wait > /dev/null',
    delete_cmd='helm uninstall cnpg --namespace cnpg-system --wait',
    image_deps=[],
    deps=[],
)

k8s_custom_deploy(
    'traefik',
    apply_cmd='helm upgrade --install traefik traefik --version 41.4.0 --repo https://traefik.github.io/charts --namespace traefik --create-namespace -f deploy/local/traefik-values.yaml --wait > /dev/null',
    delete_cmd='helm uninstall traefik --namespace traefik --wait',
    image_deps=[],
    deps=['deploy/local/traefik-values.yaml'],
)


# ---- ordering -------------------------------------------------------------
# Cross-resource ordering where a CRD or Secret must exist first:
# Cluster CR after the CNPG operator, IngressRoute after the Traefik chart,
# app after its database secret. (An earlier wedge under `tilt ci` traced
# to a misused `labels=` here, not to resource_deps — tilt up is the
# vehicle; the app's runtime DB ordering is still the init-container's
# crash-loop, this is only apply-order.)
k8s_resource('fluxvale-cnpg', resource_deps=['cnpg'])
k8s_resource('ingressroute', resource_deps=['traefik'])
k8s_resource('fluxvale-platform', resource_deps=['fluxvale-cnpg'])
