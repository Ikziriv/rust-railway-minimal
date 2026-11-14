# Footprint tuning deep dive

## Cargo release profile matrix

| Goal | opt-level | lto | codegen-units | Notes |
| --- | --- | --- | --- | --- |
| Fastest runtime | `3` | `"fat"` | 1 | default for a web service |
| Smallest binary | `"z"` | `"fat"` | 1 | `"z"` can be slower on hot paths |
| Balanced size/speed | `"s"` | `"thin"` | 1 | good middle ground |
| Fastest builds | `3` | `"thin"` | 16 | trade runtime + size for build CPU |

Always add:

- `panic = "abort"` — removes unwinding tables. Skip only if a dependency relies on `catch_unwind` or unwinding across `extern "C"`.
- `strip = true` (or `"symbols"`/`"debuginfo"`) — smaller image, zero runtime cost.

Measure with `cargo bloat --release --crates` and `ls -lh target/release/myapp`.

## Allocator

Replace the system allocator for lower memory overhead and less fragmentation:

```toml
[dependencies]
mimalloc = { version = "0.1", default-features = false }
```

```rust
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;
```

| Allocator | When |
| --- | --- |
| `mimalloc` | default — low fragmentation, good multi-threaded perf |
| `tikv-jemallocator` | heavy allocation churn; want `MALLOC_CONF` tuning knobs |
| `snmalloc` | many NUMA cores / large machines (rare on Railway) |

## Async runtime (tokio)

- Cap `worker_threads` to the container's vCPU, not the host's: `#[tokio::main(flavor = "multi_thread", worker_threads = 2)]`. Oversubscribing threads wastes memory and causes context-switch churn.
- Enable only needed features: `macros`, `rt-multi-thread`, `net`, `signal` (add `time`, `sync` as used). `features = ["full"]` drags in unused code = bigger binary + slower compile.
- Stick with epoll; `io-uring` gives no win on typical Railway container sizes.

## Network

- Reuse one `reqwest::Client` (or a pooled `hyper` client) instead of building a client per request; set `pool_max_idle_per_host` and `tcp_keepalive`.
- Prefer HTTP/2 (multiplexed, fewer sockets) for internal service-to-service calls; it also lowers memory vs many HTTP/1.1 connections.
- Compression (`gzip`/`brotli`) shrinks bytes but burns CPU. On a 0.5 vCPU container, compress only responses above ~1 KiB, or skip it and let Railway's CDN/edge handle it.
- Return small payloads: `serde_json` with `skip_serializing_if`, avoid embedding large blobs.
- Prefer `rustls` over `native-tls`/OpenSSL (`reqwest`'s `rustls-tls` feature) so the runtime image ships no `libssl3` — smaller image, less CVE surface.

## Graceful shutdown

Railway sends SIGTERM, waits `drainingSeconds`, then SIGKILL. Handle SIGTERM so in-flight requests drain and the new deploy is clean:

```rust
use tokio::signal::unix::{signal, SignalKind};

tokio::select! {
    _ = axum::serve(listener, app) => {}
    _ = shutdown_signal() => {}
}

async fn shutdown_signal() {
    let mut term = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    term.recv().await;
}
```

Set `deploy.drainingSeconds` (or the IaC equivalent) to match your longest request, so the overlap deploy doesn't kill long-lived work.

## Measuring

- `railway metrics` — CPU / memory / network per service.
- `railway ssh` → `cat /proc/self/status` or inspect `/sys/fs/cgroup` for real RSS vs the limit.
- `railway logs` — watch for OOMKilled restarts and slow requests.
