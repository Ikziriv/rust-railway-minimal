# Leptos SSR + hydration Docker build

A Leptos full-stack app produces **two** targets from one workspace: the `app` crate (a WASM hydration library) and the `server` crate (an Axum SSR binary). A plain `cargo build --release` Dockerfile builds neither the browser bundle nor the static site, so the deploy serves nothing. Read this before scaffolding a Dockerfile for a Leptos app.

## The pipeline, in order

1. **CSS** — build Tailwind (v4 needs Node + `@tailwindcss/cli`; `cargo-leptos` 0.3.x can't do Tailwind v4) into `target/site/pkg/`.
2. **WASM client** — `cargo build -p app --target wasm32-unknown-unknown --features hydrate --no-default-features --release`.
3. **Bindings** — `wasm-bindgen --target web` into `target/site/pkg/`.
4. **Shrink** — `wasm-opt -Oz` on the `.wasm`.
5. **Hash + precompress** — content-hash the JS/WASM (`hash_files=true`), then pre-gzip/brotli twins so `ServeDir` ships them with zero per-hit encoder CPU.
6. **SSR server** — `cargo build -p server --features ssr --no-default-features --release`, `strip` the binary.
7. **Runtime** — copy the binary + `target/site` + `Cargo.toml` into a minimal non-root image.

## Two profiles, two goals

```toml
[profile.release]              # workspace default
opt-level = "z"                # wasm: smallest browser payload
lto = "thin"
codegen-units = 16

[profile.release.package.server]
opt-level = 3                  # server binary: speed, not size

[profile.release.package.app]
opt-level = "z"
```

Fat LTO + `codegen-units = 1` buys ~10-20% off the WASM every visitor downloads — apply it only to the `app` wasm build. Keep the SSR build at `opt-level = 3` with LTO **off**: on a large monomorphized view tree, `-O3` + LTO can OOM LLVM on the builder. Cap `CARGO_BUILD_JOBS` (e.g. `4`) so parallel LLVM backend threads never exceed the container's cgroup RAM on 32-vCPU cloud hosts.

## Gotchas that only fail at runtime

- **`wasm-bindgen` CLI version must match `Cargo.lock`.** Pin a prebuilt binary (GitHub release) — `cargo install wasm-bindgen-cli` recompiles ~200 crates per cold build. Guard it in the Dockerfile: assert the CLI version equals the `wasm-bindgen` crate in `Cargo.lock`, and fail the build on drift.
- **`wasm-opt` from Debian apt is too old.** bookworm ships binaryen 109, which corrupts wasm-bindgen's multi-table output (browser `RangeError: failed to grow table`). Use a GitHub release >= 116.
- **`cargo install cargo-chef` is slow** — use the prebuilt musl binary (see `dockerfile-multistage.md`).
- **Leptos needs `Cargo.toml` in the runtime image** — `get_configuration` deserializes `[[workspace.metadata.leptos]]` at startup.
- **Do not set `LEPTOS_SITE_ADDR` in the runtime** — it pins port 3000 and breaks the PaaS `$PORT` scan. Leave it unset; the server binds `0.0.0.0:$PORT`.
- Set `LEPTOS_ENV=PROD`, `LEPTOS_SITE_ROOT=target/site`, `RUST_LOG=info`. Any malformed `LEPTOS_*` env value breaks `get_configuration` and silently falls back to `hash_files=false`.

## Runtime image

```dockerfile
FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 curl \
  && rm -rf /var/lib/apt/lists/* && useradd -m app
WORKDIR /app
COPY --from=builder /out/server ./server
COPY --from=builder /app/target/site ./target/site
COPY --from=builder /app/Cargo.toml ./Cargo.toml
USER app
EXPOSE 3000
ENV LEPTOS_SITE_ROOT="target/site" LEPTOS_ENV="PROD" RUST_LOG="info"
CMD ["./server"]
```

Needs `curl` for the Docker `HEALTHCHECK`, `libssl3` if the server links OpenSSL (use `rustls` to avoid it), and `ca-certificates` for outbound HTTPS.

## Railway specifics

- `watchPatterns` — only trigger rebuilds on `app/**`, `server/**`, `style/**`, `public/**`, `Cargo.toml`, `Cargo.lock`, `Dockerfile`, `.dockerignore`, `package.json`; doc/workflow edits shouldn't cost a full Rust+WASM build.
- Build cache mounts need ids of the form `s/<service-id>-<name>` (Railway rejects env/ARG there); reusing them across `cargo chef cook` and `cargo build` is what makes deps not recompile.
- `hash_files=true` + immutable cache headers on `/pkg` means repeat visits cost ~0 Railway egress; the precompressed `.br`/`.gz` twins are the rest of the network win.
