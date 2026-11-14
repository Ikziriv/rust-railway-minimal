# Railway configuration & CLI reference

## Infrastructure as Code (`.railway/railway.ts`) — recommended

Config-as-Code (`railway.json`/`railway.toml`) is deprecated and works only until 2026-12-01. IaC is the supported path.

```bash
railway config init        # scaffold .railway/railway.ts
railway config pull        # import existing project state
railway config plan        # preview changes
railway config apply       # apply changes
```

```ts
import { defineRailway, project, service, postgres } from "railway/iac";

export default defineRailway((ctx) => {
  const prod = ctx.environment === "production";
  const db = postgres("postgres");

  // Omitting `source` manages service settings without declaring a repo/image.
  const web = service("web", {
    healthcheck: "/health",
    healthcheckTimeout: 30,
    replicas: prod ? 2 : 1, // default 1; each replica doubles footprint
    env: { DATABASE_URL: db.env.DATABASE_URL },
  });

  return project("my-app", { resources: [web] });
});
```

Key fields on `service()`: `source` (github/image), `build`, `start`, `preDeploy`, `healthcheck`, `healthcheckTimeout`, `replicas`, `env`, `domains`, `volumeMounts`, `tracing`. `replicas` is a number or `{ region: count }`; default to `1` — each replica doubles CPU/RSS.

Helpers: `postgres()`, `redis()`, `mysql()`, `mongo()`, `volume()`, `bucket()`, `group()`, `preserve()` (keep an existing secret value).

## Config-as-Code (`railway.json`) — legacy

Still read for existing services. Full surface:

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build": {
    "builder": "RAILPACK",
    "dockerfilePath": "Dockerfile",
    "buildCommand": "cargo build --release",
    "watchPatterns": ["src/**", "Cargo.toml"]
  },
  "deploy": {
    "startCommand": null,
    "preDeployCommand": ["..."],
    "healthcheckPath": "/health",
    "healthcheckTimeout": 60,
    "restartPolicyType": "ON_FAILURE",
    "restartPolicyMaxRetries": 3,
    "overlapSeconds": "60",
    "drainingSeconds": "10"
  },
  "environments": {
    "production": { "deploy": { "startCommand": null } }
  }
}
```

Builders: `RAILPACK` (default) or `DOCKERFILE`. Railway always builds with a Dockerfile if it finds one. `startCommand: null` when the Dockerfile `CMD` (or Railpack auto-detect) already handles startup.

## Environment variables

- `PORT` — Railway injects the port your app must bind (default 3000). Read it, don't hard-code.
- **Private network** — reference other services by their private domain (e.g. `${{db.RAILWAY_PRIVATE_DOMAIN}}`) instead of the public URL; private traffic avoids public egress = cheaper and faster.
- `railway variable set KEY=value` · `railway variable list` · `railway variable delete KEY`.

## CLI workflow

```bash
railway login
railway init                                   # new project
railway link                                   # link existing
railway up                                     # build + deploy
railway up --detach                            # deploy, no log tail
railway logs                                   # runtime logs
railway logs --build                           # build logs
railway metrics                                # CPU/mem/net
railway usage                                  # cost breakdown
railway scale -s web                           # replicas (interactive)
railway ssh                                    # shell into the container
railway run -- cargo test                      # run with linked env vars
railway redeploy                               # redeploy latest
railway down                                   # remove latest deployment
railway environment new staging                # environments
railway volume add                             # persistent volume
```

CI tokens: set `RAILWAY_TOKEN` (project-level) or `RAILWAY_API_TOKEN` (account-level) instead of interactive login.
