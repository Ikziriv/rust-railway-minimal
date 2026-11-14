# How to Deploy Rust on Railway with the Smallest Possible Footprint

*Railway bills you for build CPU, container vCPU/RSS, and egress. A handful of Docker and Cargo choices keep all three small.*

Railway meters build CPU and RAM as usage. A cold `cargo install cargo-chef` recompiles roughly a hundred crates every deploy — before your code even builds. That's money spent compiling dependencies you didn't write, on every push.

Rust already starts small: no runtime, no garbage collector, a static binary you can run from a nearly-empty image. But *small* is a baseline, not a guarantee. The gap between a default Rust-on-Railway deploy and a tuned one is minutes off every build and a real margin off every bill.

This is the playbook I use — the one behind the `rust-railway-minimal` skill. By the end you'll have a Dockerfile, a Cargo profile, and a Railway config that spend as little as possible on the platform.

## What Railway actually bills you for

Three metered things:

1. **Build usage** — CPU and RAM while your image builds.
2. **Container usage** — vCPU and memory (RSS) while it runs.
3. **Egress** — bytes out.

Most guides optimize one of them. The moves below hit all three, because they're connected: a smaller image means less egress on pull and faster cold starts; a cached build means less build CPU; a capped runtime means less idle vCPU.

## 1. `.dockerignore` first — `target/` is the silent tax

`railway up` uploads your source. Every `COPY .` in the Dockerfile then feeds off the build context. If `target/` is in there, you're shipping gigabytes.

```dockerignore
target
.git
.gitignore
Dockerfile
.dockerignore
.env
*.md
```

The `target/` line alone is the biggest win. A built Rust workspace can carry a multi-gigabyte `target/` directory; you upload it on every deploy, and it does nothing in the image.

## 2. A multi-stage Dockerfile with a cached dependency layer

The single highest-leverage line isn't about your code. It's `cargo-chef`, which fingerprints `Cargo.toml`/`Cargo.lock` and rebuilds dependencies only when they change.

```dockerfile
FROM rust:1.88-slim AS chef
WORKDIR /app
# Prebuilt cargo-chef — `cargo install` recompiles ~100 crates every cold build.
RUN curl -fsSL https://github.com/LukeMathWalker/cargo-chef/releases/download/v0.1.78/cargo-chef-x86_64-unknown-linux-musl.tar.xz \
  | tar -xJ -C /usr/local/bin --strip-components=1 \
      cargo-chef-x86_64-unknown-linux-musl/cargo-chef

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=builder /app/target/release/myapp /app
ENV PORT=3000
EXPOSE 3000
CMD ["/app"]
```

Two details most guides get wrong:

- **Use the prebuilt `cargo-chef` binary, not `cargo install`.** `cargo install cargo-chef` compiles ~100 crates on every cold build. The prebuilt musl binary is one `curl`.
- **Pin the Rust minor.** `rust:1.88-slim`, not `rust:1-slim`, so a redeploy can't silently bump the toolchain and change your binary.

The final stage is `distroless/cc-debian12:nonroot` — no shell, no package manager, CA certs included, runs non-root. For the absolute smallest image, go `FROM scratch` with a static musl build.

## 3. The release profile: five lines that do the most work

```toml
[profile.release]
opt-level = 3     # "z"/"s" if image size beats runtime CPU
lto = "fat"       # cross-crate dead-code elimination
codegen-units = 1 # best optimization + smallest, slower compile
panic = "abort"   # drop unwinding tables
strip = true      # strip symbols + debuginfo
```

`lto = "fat"` + `codegen-units = 1` lets the linker eliminate dead code across the whole dependency graph. `panic = "abort"` drops the unwinding tables. `strip = true` removes symbols and debuginfo. Together they shrink the binary and image — and a smaller binary is a smaller image, less egress, and a faster cold start.

## 4. Trim the runtime, not just the binary

The image is only half the footprint. The running process spends CPU and memory too:

- **Allocator.** Swap in `mimalloc` (or jemalloc) as the `#[global_allocator]`. Less fragmentation, lower multi-thread overhead than the system allocator.
- **Threads.** Cap `tokio`'s `worker_threads` to the container's vCPU — `#[tokio::main(flavor = "multi_thread", worker_threads = 2)]`. Default tokio spawns one thread per host core, which oversubscribes a small container and burns memory for nothing.
- **Features.** Never `tokio = { features = ["full"] }`. Pull `macros`, `rt-multi-thread`, `net`, `signal` individually.
- **TLS.** Prefer `rustls` over OpenSSL (`reqwest`'s `rustls-tls` feature) so the runtime image ships no `libssl3` — smaller image, less CVE surface.
- **Network.** Reuse one HTTP `Client` (connection pooling) and prefer HTTP/2 for internal calls.

## 5. Build speed is a cost too

`lto = "fat"` + `codegen-units = 1` make linking the slow step. Swap in the `mold` linker in the builder stage — it only costs build time, never the image.

And persist the Cargo registry so `cargo chef cook` doesn't re-download the world:

```dockerfile
RUN --mount=type=cache,id=s/<service-id>-cargo-registry,target=/usr/local/cargo/registry \
    cargo chef cook --release --recipe-path recipe.json
```

Railway requires cache-mount ids of the form `s/<service-id>-<name>` (env/ARG are rejected). Reuse the same id across `cargo chef cook` and `cargo build` — that's what keeps dependencies from recompiling between deploys.

## 6. Configure the service, not just the image

Railway's healthcheck is `healthcheckPath` — an HTTP probe against your `/health` route (not the Docker `HEALTHCHECK` directive). Keep it trivial and DB-free:

```rust
async fn health() -> impl IntoResponse { "ok" }
```

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build": { "builder": "DOCKERFILE", "dockerfilePath": "Dockerfile" },
  "deploy": {
    "healthcheckPath": "/health",
    "healthcheckTimeout": 60,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 3
  }
}
```

Bind `0.0.0.0:$PORT` (Railway injects `PORT`), and keep `replicas` at 1 unless you need HA — every replica doubles the footprint. One caveat: `railway.json` (Config-as-Code) is deprecated and works until 2026-12-01; for new work use Infrastructure-as-Code in `.railway/railway.ts` via `railway config init`.

## 7. Verify the footprint actually dropped

```bash
railway up
railway metrics   # CPU / memory / network
railway usage     # what it costs
```

Watch `railway metrics` right after a deploy. A spike that doesn't drop means the profile, allocator, or thread settings aren't landing.

## The full-stack caveat

If you're shipping a Leptos SSR app (or anything with a WASM hydration bundle), a plain `cargo build --release` Dockerfile won't work — you need a second WASM build, `wasm-bindgen`, `wasm-opt`, and content-hashed + precompressed assets. Same principles, more stages: size the browser payload, precompress, and cache the build.

## The whole thing, ready to copy

Everything above is packaged as an installable skill:

```bash
npx skills add Ikziriv/rust-railway-minimal -g -y
```

It ships a `scaffold.sh` that generates the `.dockerignore`, `Dockerfile`, `.railway/railway.ts`, and release profile in one shot — plus references that go deeper on `scratch`/musl builds, allocators, and Railway IaC.

---

## Image suggestions

1. **Hero/cover** — a compact diagram of the three metered costs (build CPU · vCPU/RSS · egress) with the levers that shrink each. *Purpose:* set the frame in one glance. (Midjourney: `--ar 16:9`.)
2. **After "multi-stage Dockerfile"** — a horizontal flow of the four stages (`chef → planner → builder → distroless`) with the cached layer highlighted. *Purpose:* make the caching story visual.

## Title alternatives

1. **Rust Won't Make Your Railway Bill Small. Your Dockerfile Will.**
2. **A Minimal Rust Dockerfile for Railway: cargo-chef, distroless, One Release Profile**
3. **7 Choices That Keep a Rust Service Minimal on Railway**
