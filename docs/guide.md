# rust-railway-minimal — Detailed Guide

A reference manual for using the `rust-railway-minimal` skill: how it's built, when each piece fires, and how to run it end to end.

## What it is

An agent skill that ships Rust to Railway as a minimal Docker image. One leading word drives every decision: **footprint** — CPU, memory, network, and image size, traded against what Railway bills.

## Installation

```bash
# as an agent skill (recommended)
npx skills add Ikziriv/rust-railway-minimal -g -y

# or clone directly
git clone https://github.com/Ikziriv/rust-railway-minimal.git ~/.agents/skills/rust-railway-minimal
```

## When it triggers

The skill's `description` is the only thing the agent reads to decide whether to load it. It fires on requests like:

- "deploy this Rust service on Railway"
- "shrink my Axum service's memory/CPU"
- "write a minimal Dockerfile for Rust"
- "optimize my Rust container image"

## Layout

```
SKILL.md                          # the workflow (5 steps, canonical configs inline)
references/
  dockerfile-multistage.md        # scratch/musl/static, non-root, mold, cache mounts
  footprint-tuning.md             # Cargo matrix, allocators, tokio, network, shutdown
  railway-iac-cli.md              # .railway/railway.ts, railway.json, full CLI
  leptos-ssr.md                   # WASM + SSR multi-target build
scripts/
  scaffold.sh                     # generate .dockerignore, Dockerfile, IaC, profile
docs/
  deploy-rust-on-railway-minimal-footprint.md  # the blog article
```

`SKILL.md` is the common path and always loads. The `references/` load on demand — the agent reads a file only when the pointer fires (for example, `leptos-ssr.md` only for a full-stack app).

## The five steps

1. **`.dockerignore`** — exclude `target`, `.git`, `.env`; the build context feeds every `COPY`.
2. **Multi-stage Dockerfile** — prebuilt `cargo-chef` for a cached dependency layer, a `distroless/cc-debian12:nonroot` runtime, and a pinned Rust minor.
3. **Release profile** — `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`, `strip = true`.
4. **Runtime trim** — `mimalloc`/jemalloc, cap `tokio` `worker_threads`, minimal features, `rustls`, a pooled HTTP client.
5. **Configure + verify** — `healthcheckPath`, `restartPolicyType`, `replicas: 1`, then `railway metrics` / `railway usage`.

## The scaffold script

```bash
sh scripts/scaffold.sh <binary-name> [port] [cargo-chef-version]
```

| Arg | Default | Purpose |
| --- | --- | --- |
| binary-name | (required) | the release binary name (the `COPY` target) |
| port | 3000 | `PORT` / `EXPOSE` in the image |
| cargo-chef-version | v0.1.78 | the prebuilt cargo-chef release to fetch |

It writes four files into the current directory:

- `.dockerignore`
- `Dockerfile`
- `.railway/railway.ts` (IaC, `replicas: 1`)
- `Cargo.toml.release` (merge into your `[profile.release]`)

## Reference map — which file to read

| You need… | Read |
| --- | --- |
| The smallest image (`scratch`, static musl) | `references/dockerfile-multistage.md` |
| The size-vs-speed Cargo matrix, allocators | `references/footprint-tuning.md` |
| `.railway/railway.ts`, `railway.json`, CLI commands | `references/railway-iac-cli.md` |
| A Leptos SSR / WASM + hydration build | `references/leptos-ssr.md` |

## Corrections vs. common stale advice

- **The zero-config builder is `RAILPACK`, not Nixpacks.** This skill uses a Dockerfile for full control.
- **Config-as-Code (`railway.json`/`railway.toml`) is deprecated** (works until 2026-12-01). Use Infrastructure-as-Code: `.railway/railway.ts` via `railway config init`.
- **Railway's healthcheck is `healthcheckPath`** — an HTTP probe, not the Docker `HEALTHCHECK` directive.

## Verifying the footprint

```bash
railway up
railway metrics   # CPU / memory / network
railway usage     # cost
railway logs      # watch for OOMKilled / slow requests
```

A deploy whose metrics spike and don't drop means a lever isn't landing — re-check the release profile, allocator, and thread cap.
