# Dockerfile: multi-stage & minimal runtime image

## Runtime base options

| Base | Size | Shell | CA certs | Notes |
| --- | --- | --- | --- | --- |
| `gcr.io/distroless/cc-debian12:nonroot` | ~20 MB | none | yes | Recommended default; runs non-root |
| `scratch` | ~0 | none | no | Smallest; needs static musl + copied CA certs |
| `alpine:3.x` | ~5 MB | yes | copy | musl; needs musl-compiled binary |

## distroless cc (recommended)

Shown in SKILL.md. Points:

- `cc-debian12` ships `libgcc`/`libstdc++`, so it runs glibc-dynamic Rust binaries with no extra files.
- `:nonroot` runs as uid 65532. A glibc build binds fine; nothing to copy for the binary itself.
- distroless cc already includes `/etc/ssl/certs/ca-certificates.crt` for outbound HTTPS. Copy it yourself only if you see TLS verification errors.
- **When distroless is wrong:** if the image needs `curl` (for a Docker `HEALTHCHECK`), `libssl3` (OpenSSL runtime), or extra files the app reads at startup (e.g. leptos's `Cargo.toml`), distroless has no shell/package manager to provide them. Use `debian:bookworm-slim` + `useradd` + `USER app` instead — still small, still non-root, but extensible.

## scratch (absolute smallest)

Requires a fully static binary:

```dockerfile
FROM rust:alpine AS builder
WORKDIR /app
RUN apk add --no-cache musl-dev ca-certificates \
    && rustup target add x86_64-unknown-linux-musl
COPY . .
RUN cargo build --release --target x86_64-unknown-linux-musl

FROM scratch
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/myapp /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV PORT=3000
EXPOSE 3000
USER 65532:65532
ENTRYPOINT ["/app"]
```

Caveats:

- No `/etc/resolv.conf` in the image, but Railway mounts one at runtime — DNS works.
- No timezone data; add `chrono` + `iana-time-zone` or a `tzdata` copy if you format local times.
- musl's allocator is simple and can be a throughput cliff; pair the musl build with `mimalloc` as `#[global_allocator]`.

## alpine (small + debuggable)

Keep a shell for `railway ssh` debugging:

```dockerfile
FROM rust:alpine AS builder
RUN apk add --no-cache musl-dev
COPY . .
RUN cargo build --release

FROM alpine:3
RUN apk add --no-cache ca-certificates && adduser -D app
COPY --from=builder /app/target/release/myapp /usr/local/bin/myapp
USER app
ENV PORT=3000
EXPOSE 3000
CMD ["myapp"]
```

## Non-root & port binding

Run non-root everywhere; ports >= 1024 bind fine as non-root. Bind `0.0.0.0` (all interfaces) so the Railway proxy reaches you. Railway injects `PORT` (default 3000).

## cargo-chef caching

`cargo chef prepare` fingerprints dependencies into `recipe.json`; `cargo chef cook` builds them in a cached layer. Recompilation only happens when `Cargo.toml`/`Cargo.lock` change. This is the single biggest win for Railway build CPU and slow deploys — do not skip it on any Rust project that rebuilds often.

Install `cargo-chef` as a prebuilt binary (`curl` the GitHub release, `tar` into `/usr/local/bin`) instead of `cargo install cargo-chef` — the install path recompiles ~100 crates on every cold build.

## Faster builds in the builder stage

`lto = "fat"` + `codegen-units = 1` (the profile above) make linking the slow step. Swap the linker for `mold` in the builder stage to cut link time dramatically:

```dockerfile
FROM rust:1-slim AS chef
RUN apt-get update \
    && apt-get install -y mold clang \
    && rm -rf /var/lib/apt/lists/*
# ...cargo-chef stages unchanged, then:
RUN cargo build --release
```

```toml
# .cargo/config.toml
[target.x86_64-unknown-linux-gnu]
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
```

`mold` only affects build time, not the final image — use it whenever you rebuild often. (A compiler cache like `sccache` is an alternative, but it is finicky across Docker layers; prefer `mold` first.)

## Toolchain pinning

Pin the Rust minor in the base image — `rust:1.88-slim`, not `rust:1-slim` — so a redeploy can't silently bump the toolchain and change the binary. Bump the tag deliberately, matching your local `rustc --version`. (Alternatively commit a `rust-toolchain.toml` and let `rustup` install the pinned toolchain in the image.)

## Railway build cache mounts

Persist the Cargo registry across builds so `cargo chef cook` doesn't re-download or re-compile the world:

```dockerfile
RUN --mount=type=cache,id=s/<service-id>-cargo-registry,target=/usr/local/cargo/registry \
    cargo chef cook --release --recipe-path recipe.json
```

Railway requires cache-mount ids of the form `s/<service-id>-<name>` (env/ARG are rejected). Reuse the same id across `cargo chef cook` and `cargo build` — that's what makes dependencies not recompile between deploys.
