# Production release image (docs/deployment.md pipeline, #98) — the OTP
# release whose delta from the dev image (`Dockerfile.dev`,
# `mix phx.server`) is exactly what staging verifies.
#
# Base matches the Tiltfile's BASE_IMAGE pin: hexpm appends rebuild
# suffixes (e.g. erlang-29.1.2), so the full tag can't be composed
# from mise.toml alone — CI asserts the tag still matches mise.toml's
# BEAM pins (single source of truth, the Tiltfile rule).
# 29.1.2 floor (#226): OTP ≤28 musl builds abort at beam startup on
# AVX-512/AMX hosts (sigaltstack ENOMEM, erlang/otp#11248) — the fix
# (sysconf-sized stack, erlang/otp#11376) shipped in 29.1.
ARG BASE_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.2-alpine-3.24.3
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
COPY storybook storybook

# Pre-built artifacts (#230 class), staged by .github/actions/prebuilt:
# the mdex_native tarball goes where rustler_precompiled looks (env
# override of its cache dir) so `mix compile` never fetches the NIF
# from GitHub Releases (httpc header limit — this exact fetch reded
# deploy-image on #235's merge); the tailwind binary goes to the path
# tailwind-elixir computes so `mix assets.deploy`'s auto-install
# fetches nothing. Local release builds: the dirs hold only .gitkeep,
# default fetch paths unchanged.
COPY .prebuilt/mdex_native/ /app/.prebuilt/
ENV RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=/app/.prebuilt
COPY .prebuilt/tailwind/ /app/_build/

# Assets: Hex-managed tailwind/esbuild — no Node. phx.digest writes the
# cache manifest prod.exs configures.
RUN mix compile && mix assets.deploy && mix release

# Runtime alpine matches the builder image's (3.24.3): the release's
# NIFs and the musl the release tree expects must stay in lockstep.
FROM alpine:3.24.3

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
