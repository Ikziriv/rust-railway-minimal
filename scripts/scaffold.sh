#!/usr/bin/env sh
# Scaffold a minimal-footprint Rust service for Railway.
# Emits Dockerfile, .railway/railway.ts, and a [profile.release] fragment.
# Usage: sh scaffold.sh <binary-name> [port] [cargo-chef-version]
set -eu

name="${1:?usage: scaffold.sh <binary-name> [port] [cargo-chef-version]}"
port="${2:-3000}"
chef_version="${3:-v0.1.78}"

mkdir -p .railway

# --- .dockerignore ---
cat > .dockerignore <<'EOF'
target
.git
.gitignore
Dockerfile
.dockerignore
.env
*.md
EOF

# --- release profile fragment (merge into Cargo.toml) ---
cat > Cargo.toml.release <<'EOF'
[profile.release]
opt-level = 3
lto = "fat"
codegen-units = 1
panic = "abort"
strip = true
EOF

# --- multi-stage Dockerfile ---
cat > Dockerfile <<EOF
FROM rust:1-slim AS chef
WORKDIR /app
# Prebuilt cargo-chef — cargo install recompiles ~100 crates every cold build.
RUN curl -fsSL https://github.com/LukeMathWalker/cargo-chef/releases/download/${chef_version}/cargo-chef-x86_64-unknown-linux-musl.tar.xz | tar -xJ -C /usr/local/bin --strip-components=1 cargo-chef-x86_64-unknown-linux-musl/cargo-chef

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=builder /app/target/release/${name} /app
ENV PORT=${port}
EXPOSE ${port}
CMD ["/app"]
EOF

# --- Infrastructure-as-Code config ---
cat > .railway/railway.ts <<EOF
import { defineRailway, project, service } from "railway/iac";

export default defineRailway(() => {
  const web = service("web", {
    healthcheck: "/health",
    healthcheckTimeout: 30,
    replicas: 1, // 1 replica = minimal footprint; bump only for HA
  });

  return project("${name}", { resources: [web] });
});
EOF

echo "Scaffolded: .dockerignore, Dockerfile, .railway/railway.ts, Cargo.toml.release"
echo "Next:"
echo "  merge Cargo.toml.release into your [profile.release]"
echo "  add a GET /health handler that returns 200"
echo "  railway up"
