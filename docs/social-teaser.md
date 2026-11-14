# Social teasers — rust-railway-minimal

Copy-paste teasers for announcing the article/skill. Each is a distinct platform, not three rewordings.

## LinkedIn

Rust doesn't make your Railway bill small. Your Dockerfile does.

Railway bills you for three things — build CPU, container vCPU/RSS, and egress. A default Rust deploy spends all three without trying.

Five lines in `Cargo.toml`, a multi-stage Dockerfile, and a pinned toolchain turned a service from "fine" to genuinely cheap:

- `lto = "fat"` + `codegen-units = 1` + `strip` — smaller binary, smaller image, less egress
- prebuilt `cargo-chef`, not `cargo install` (that one compiles ~100 crates on every cold build)
- `distroless/cc-debian12:nonroot` — no shell, no package manager, runs non-root
- `mimalloc` + a capped `tokio` runtime — less idle CPU, less RSS

I wrote it up as a playbook and packaged it as an installable skill:

`npx skills add Ikziriv/rust-railway-minimal -g -y`

Article + repo: https://github.com/Ikziriv/rust-railway-minimal

## X / Twitter

Your Rust deploy is paying for idle CPU, build time, and egress it doesn't need. A 5-line Cargo profile, a multi-stage Dockerfile, and a pinned toolchain fix most of it.

Playbook → `npx skills add Ikziriv/rust-railway-minimal`

## dev.to / short cross-post

**How to Deploy Rust on Railway with the Smallest Possible Footprint**

Railway meters build CPU, container vCPU/RSS, and egress — and a default Rust deploy spends all three without trying. This is the playbook: `.dockerignore`, a cached multi-stage build, a 5-line release profile, and a capped runtime.
