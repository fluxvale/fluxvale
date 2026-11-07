# Release image for the MCP server (W3a of #484) — the platform
# release image's shape (#98), transposed to Rust: native build in a
# pinned alpine builder, minimal alpine runtime. No cross-compile, no
# --target juggling: the rust alpine image's host triple IS musl, so a
# plain cargo build yields the static binary the runtime runs.
#
# The pin mirrors the platform's BASE_IMAGE discipline: CI asserts
# RUST_IMAGE carries rust-toolchain.toml's channel (the file local
# rustup and mcp-gates both select), so the image can never drift to a
# different compiler than the repo's gates ran on.
ARG RUST_IMAGE=rust:1.99.1-alpine3.24
FROM ${RUST_IMAGE} AS builder

# The builder image ships gcc + musl-dev (its purpose is static musl
# builds) — nothing to apk add. Toolchain files are deliberately NOT
# copied: rustup would honor them, and the CI assert keeps the image
# pin equal anyway.
WORKDIR /build

# Deps layer (the platform Dockerfile's manifest-first pattern):
# manifests + lock + stub sources build the whole dependency graph, so
# source edits rebuild the app, not rmcp/tokio/axum. Stub sources
# stand in for the two local crates the manifests reference — the
# server path-depends on fluxvale-api, which inherits
# [workspace.package] from crates/Cargo.toml, so the workspace
# manifest rides the context too (the root .dockerignore scopes the
# context to exactly these trees).
COPY crates/Cargo.toml crates/Cargo.toml
COPY crates/fluxvale-api/Cargo.toml crates/fluxvale-api/Cargo.toml
COPY apps/mcp/Cargo.toml apps/mcp/Cargo.toml
COPY apps/mcp/Cargo.lock apps/mcp/Cargo.lock
RUN mkdir -p crates/fluxvale-api/src apps/mcp/src \
 && echo '' > crates/fluxvale-api/src/lib.rs \
 && echo 'fn main() {}' > apps/mcp/src/main.rs \
 && cargo build --release --locked --manifest-path apps/mcp/Cargo.toml

# Real sources. COPY stamps checkout mtimes that can predate the stub
# build, and cargo fingerprints by mtime — touch forces the rebuild
# that ships the real binary, never the stub.
COPY crates/fluxvale-api/src crates/fluxvale-api/src
COPY apps/mcp/src apps/mcp/src
RUN touch crates/fluxvale-api/src/*.rs apps/mcp/src/*.rs \
 && cargo build --release --locked --manifest-path apps/mcp/Cargo.toml

# Runtime: the platform image's base, exactly — one runtime class for
# both containers. The binary is static; ca-certificates (the outbound
# HTTPS to the platform — rustls validates the origin's cert; no
# native-tls anywhere) is the only addition.
FROM alpine:3.24.3
RUN apk add --no-cache ca-certificates \
 && adduser -D -u 10001 fluxvale

# Unprivileged, numeric uid (k8s runAsNonRoot checks the uid, not the
# name) — the platform image's same uid.
USER 10001:10001

COPY --from=builder /build/apps/mcp/target/release/fluxvale-mcp /usr/local/bin/fluxvale-mcp

EXPOSE 4600

# No ENV defaults for FLUXVALE_API_BASE_URL or MCP_ALLOWED_HOSTS: the
# image carries no config and no secrets — the deployment provides
# both, and the binary refuses to boot without the origin (fail-fast
# beats a wrong default silently calling the wrong platform).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -q -O /dev/null http://127.0.0.1:4600/health || exit 1

ENTRYPOINT ["/usr/local/bin/fluxvale-mcp"]
