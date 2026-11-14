---
name: rust-railway-minimal
description: Deploy Rust services on Railway with a Docker build tuned for the smallest possible CPU, memory, and network footprint. Use when the user wants to build a Rust service (Axum, Actix Web, Rocket, tonic, Leptos SSR, or a plain binary) as a Docker image for Railway, write a minimal multi-stage Dockerfile, shrink a Rust service's resource usage or image size, configure a service via Railway Infrastructure-as-Code or railway.json, or use the Railway CLI.
---

# Rust on Railway — minimal Docker build

The goal is one word: **footprint**. Every decision below trades it — CPU, memory, network, and image size — against cost on Railway. A Docker build gives you full control over that trade; Railway auto-detects a `Dockerfile` and builds with it.

## 1. Add a .dockerignore

`railway up` uploads your source, and the build context feeds every `COPY`. Exclude the bloat so uploads and builds stay fast:

```dockerignore
target
.git
.gitignore
Dockerfile
.dockerignore
.env
*.md
```

The `target/` entry alone is the biggest win — it can be gigabytes.

## 2. Multi-stage Dockerfile

`cargo-chef` caches your dependency layer; the final stage is a tiny non-root image:

```dockerfile
FROM rust:1-slim AS chef
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

- `cargo chef cook` rebuilds only when `Cargo.toml`/`Cargo.lock` change — the single biggest cut to Railway build CPU and slow deploys.
- `distroless/cc-debian12` = no shell, no package manager, CA certs included, runs non-root.
- For the absolute smallest image, go `FROM scratch` with a static musl build — see [references/dockerfile-multistage.md](references/dockerfile-multistage.md).
- Bind `0.0.0.0:$PORT`; Railway injects `PORT`.

> **Leptos SSR?** A full-stack (SSR + hydration) app needs a second WASM build, not a plain `cargo build`. Read [references/leptos-ssr.md](references/leptos-ssr.md) before writing the Dockerfile.

## 3. Shrink the footprint (Cargo.toml)

Add this release profile. It is the single highest-leverage change:

```toml
[profile.release]
opt-level = 3     # "z"/"s" if image size beats runtime CPU
lto = "fat"       # cross-crate dead-code elimination
codegen-units = 1 # best optimization + smallest, slower compile
panic = "abort"   # drop unwinding tables
strip = true      # strip symbols + debuginfo
```

Then trim the runtime itself:

- **Dependencies**: enable only the features you use. Never `tokio = { features = ["full"] }` — pull `macros`, `rt-multi-thread`, `net`, `signal` individually.
- **Allocator**: swap in `mimalloc` (`default-features = false`) as `#[global_allocator]` — lower fragmentation and multi-thread overhead than the system allocator.
- **Async runtime**: cap `worker_threads` to match the container's vCPU (e.g. `#[tokio::main(flavor = "multi_thread", worker_threads = 2)]`) instead of spawning one thread per core.
- **Network**: reuse one HTTP `Client` (connection pooling), prefer HTTP/2/keep-alive, and serve a trivial `/health` handler that does no work.

Deeper trade-offs (size-vs-speed matrix, jemalloc/snmalloc, compression, graceful shutdown) live in [references/footprint-tuning.md](references/footprint-tuning.md).

## 4. Configure the service on Railway

Set the builder to Docker and give it a healthcheck. Minimal `railway.json`:

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

> Config-as-Code (`railway.json`) is deprecated and works until 2026-12-01. For new work, prefer Infrastructure-as-Code in `.railway/railway.ts` — full schema in [references/railway-iac-cli.md](references/railway-iac-cli.md).

Keep `replicas` at 1 unless you need HA; every replica doubles the footprint.

## 5. Deploy and verify with the CLI

```bash
railway login
railway init          # or: railway link  (existing project)
railway up            # Dockerfile auto-detected, builds and deploys
railway logs --build  # watch the Docker build
railway logs          # runtime logs
railway metrics       # CPU / memory / network
railway usage         # what it costs
railway scale -s web  # replicas
```

Watch `railway metrics` right after `railway up`. A spike that doesn't drop means the profile/allocator/thread settings from step 3 aren't landing — read [references/footprint-tuning.md](references/footprint-tuning.md).

## Scaffold (optional)

To generate the minimal `.dockerignore`, `Dockerfile`, `.railway/railway.ts`, and a `[profile.release]` fragment in one shot, run from the project root:

```bash
sh scripts/scaffold.sh myapp 3000 v0.1.78
```

(Replace `myapp` with your binary name; the third arg pins the `cargo-chef` release and defaults to `v0.1.78`.) The script is deterministic — read [scripts/scaffold.sh](scripts/scaffold.sh) before editing it if you need custom output.

## References

- [references/dockerfile-multistage.md](references/dockerfile-multistage.md) — `scratch`/musl/static builds, non-root, CA certs, `mold` linker.
- [references/footprint-tuning.md](references/footprint-tuning.md) — Cargo matrix, allocators, tokio, network, shutdown.
- [references/railway-iac-cli.md](references/railway-iac-cli.md) — `.railway/railway.ts`, `railway.json`, full CLI.
- [references/leptos-ssr.md](references/leptos-ssr.md) — WASM + SSR multi-target build for Leptos full-stack apps.
