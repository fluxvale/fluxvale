# Production release image (docs/deployment.md pipeline, #98) — the OTP
# release whose delta from the dev image (`Dockerfile.dev`,
# `mix phx.server`) is exactly what staging verifies.
#
# Base matches the Tiltfile's BASE_IMAGE pin: hexpm appends rebuild
# suffixes (e.g. erlang-28.5.0.6), so the full tag can't be composed
# from mise.toml alone — CI asserts the tag still matches mise.toml's
# BEAM pins (single source of truth, the Tiltfile rule).
ARG BASE_IMAGE=hexpm/elixir:1.20.4-erlang-28.5.0.6-alpine-3.24.1
FROM ${BASE_IMAGE} AS builder

# git: mix fetches heroicons/daisyui as git deps. make/gcc/musl-dev:
# bcrypt_elixir (hard dep of ash_authentication) is a portable C NIF —
# same toolchain as the dev image (see Dockerfile.dev).
RUN apk add --no-cache git make gcc musl-dev

ENV MIX_ENV=prod

WORKDIR /app

# Deps layer: cached unless the lockfile changes
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# App source. priv carries repo migrations + the catalog seed YAML the
# release runs against (FluxVale.Release); rel carries the bin/server,
# bin/migrate, and bin/seed overlays `mix release` copies into the
# release tree.
COPY lib lib
COPY config config
COPY priv priv
COPY assets assets
COPY rel rel

# Assets: Hex-managed tailwind/esbuild — no Node. phx.digest writes the
# cache manifest prod.exs configures.
RUN mix compile && mix assets.deploy && mix release

FROM alpine:3.24.1

# BEAM runtime: openssl (crypto NIF), ncurses-libs, libstdc++, zlib.
# ca-certificates: outbound HTTPS (Postmark, Grafana OTLP). tzdata:
# zoneinfo lookups.
RUN apk add --no-cache openssl ncurses-libs libstdc++ zlib ca-certificates tzdata

# Unprivileged runtime user — same uid as the dev image (10001)
RUN adduser -D -u 10001 fluxvale

WORKDIR /app

# Release tree stays root-owned (a compromised runtime process must not
# overwrite its own executables — review finding); only the tmp dir is
# writable: Mix's generated bin scripts export sys.config there at boot
# (RELEASE_TMP defaults to <release root>/tmp).
COPY --from=builder /app/_build/prod/rel/flux_vale ./
RUN mkdir -p tmp && chown fluxvale:fluxvale tmp

# BUILD_SHA is the deploy pipeline's poll target (docs/deployment.md):
# /health reports sha-<BUILD_SHA>, CI tags the image sha-<BUILD_SHA>,
# watch-deploy waits for both envs to report it.
ARG BUILD_SHA
ENV BUILD_SHA=${BUILD_SHA} \
    MIX_ENV=prod

# Numeric: k8s runAsNonRoot checks the uid, not the name (dev image's rule)
USER 10001:10001

EXPOSE 4000

# bin/server sets PHX_SERVER=true and execs `start`. Kubernetes'
# `command:` replaces this wholesale — the init container runs
# bin/migrate (rel/overlays/bin/), the app container runs this default.
ENTRYPOINT ["bin/server"]
