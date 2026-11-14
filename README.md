# rust-railway-minimal

> Deploy Rust services on Railway with the smallest possible CPU, memory, and network footprint.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/rust-stable-orange.svg)](https://www.rust-lang.org)
[![Railway](https://img.shields.io/badge/deploy-Railway-6f2da8.svg)](https://railway.com)

An **agent skill** — and a copy-paste playbook — for shipping Rust to [Railway](https://railway.com) as a minimal Docker image. Covers Axum, Actix Web, Rocket, tonic, and plain binaries; a dedicated reference handles **Leptos SSR** (WASM + hydration).

The whole thing hangs on one word: **footprint**. Railway meters build CPU/RAM, container vCPU/RSS, and egress. Rust already starts small; every choice below keeps it that way.

---

## Install

```bash
# as an agent skill (recommended)
npx skills add Ikziriv/rust-railway-minimal -g -y

# or manually
mkdir -p ~/.agents/skills
git clone https://github.com/Ikziriv/rust-railway-minimal.git ~/.agents/skills/rust-railway-minimal
```

The skill auto-triggers on requests like *"deploy this Rust service on Railway"*, *"shrink my Axum service's memory/CPU"*, or *"write a minimal Dockerfile for Rust"*.

## Quick start (scaffold)

```bash
sh scripts/scaffold.sh myapp 3000 v0.1.78
```

Generates `.dockerignore`, `Dockerfile`, `.railway/railway.ts`, and a `[profile.release]` fragment. Then:

```bash
railway login
railway up            # Dockerfile auto-detected, builds and deploys
railway metrics       # watch CPU / memory / network drop
```

## The core recipe

The single highest-leverage change — a release profile:

```toml
[profile.release]
opt-level = 3     # "z"/"s" if image size beats runtime CPU
lto = "fat"       # cross-crate dead-code elimination
codegen-units = 1 # best optimization + smallest, slower compile
panic = "abort"   # drop unwinding tables
strip = true      # strip symbols + debuginfo
```

A multi-stage Dockerfile ending in a tiny non-root image:

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

And Railway config (healthcheck + restart):

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

## The levers

| Resource | Levers |
| --- | --- |
| **CPU** | `opt-level = 3`, cap `tokio` `worker_threads` to vCPU, skip compression on small instances |
| **Memory** | `mimalloc`/jemalloc global allocator, minimal crate features, no `tokio` `full` |
| **Network** | one pooled HTTP client, HTTP/2, hashed immutable assets, precompressed br/gzip |
| **Image size** | `.dockerignore`, multi-stage, distroless/`scratch`, `strip` |

## Railway gotchas

- **The zero-config builder is `RAILPACK`, not Nixpacks.** This skill uses a Dockerfile for full control; Railway auto-detects it.
- **Config-as-Code (`railway.json`/`railway.toml`) is deprecated** (works until 2026-12-01). Use Infrastructure-as-Code: `.railway/railway.ts` via `railway config init`.
- **Bind `0.0.0.0:$PORT`** — Railway injects `PORT` (default 3000).
- **`replicas: 1`** unless you need HA; every replica doubles the footprint.
- **Pin the Rust minor** (`rust:1.88-slim`, not `rust:1-slim`) for reproducible builds.
- **Persist the Cargo registry** with `--mount=type=cache,id=s/<service-id>-cargo-registry,target=/usr/local/cargo/registry` so deploys don't recompile deps.

## Repository layout

```
SKILL.md                              # the workflow (5 steps)
references/
  dockerfile-multistage.md            # scratch/musl/static, non-root, mold
  footprint-tuning.md                 # Cargo matrix, allocators, tokio, network
  railway-iac-cli.md                  # .railway/railway.ts, railway.json, CLI
  leptos-ssr.md                       # WASM + SSR multi-target build
scripts/
  scaffold.sh                         # generate the minimal deploy files
```

## Leptos SSR

Full-stack (SSR + hydration) apps need a second WASM build, not a plain `cargo build`. See [`references/leptos-ssr.md`](references/leptos-ssr.md) before writing the Dockerfile.

## License

[MIT](LICENSE)
