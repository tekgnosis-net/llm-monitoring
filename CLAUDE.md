# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Docker Compose monitoring deployment** for a fleet of vLLM servers. It contains
**no application source and no vLLM** — only configuration. vLLM itself is deployed
separately (per GPU host) and merely observed by this stack.

It ships **two independently deployable units**:

- **`agent/`** — runs on each GPU server. Just the NVIDIA **DCGM exporter** (`:9400`).
  vLLM already exposes its own Prometheus metrics on `:8000/metrics`, so nothing else
  is needed on the GPU host. Stateless, secret-free.
- **`monitoring/`** — runs on one dedicated monitoring host. A **central Prometheus**
  scrapes every GPU server's vLLM (`:8000`) and DCGM (`:9400`) over the LAN, plus
  **Grafana** (consolidated dashboards) and **Alertmanager** (email alerts).

Design rationale and the rejected per-agent-Prometheus alternative are recorded in
`docs/superpowers/specs/2026-06-22-monitoring-split-design.md`.

## Topology & data flow

```
GPU servers (agent/)                    Monitoring host (monitoring/)
  vLLM    :8000/metrics  ───scrape──►   Prometheus :9090 ──► Alertmanager :9093 ──► email
  DCGM    :9400          ───scrape──►        │
                                             └──► Grafana :3000  ($server dropdown)
```

Every scrape target is labelled with `server=<name>` (from `GPU_HOSTS`), so one
Prometheus + one Grafana datasource cleanly separates hosts, and alerts carry the
firing server's name.

## Commands

No build/lint/test tooling — this is Docker Compose lifecycle + config validation.

```bash
# On each GPU server:
cd agent && docker compose up -d
curl http://localhost:9400/metrics            # confirm DCGM exporter

# On the monitoring host:
cd monitoring && cp .env.example .env         # then edit .env
docker compose up -d
docker compose config                         # validate/expand compose + .env substitution
docker compose logs config-render             # see what targets/SMTP were rendered
docker compose up -d                          # re-run after editing .env (re-renders configs)
```

UIs: Grafana `:3000`, Prometheus `:9090`, Alertmanager `:9093`.

**Adding/removing a GPU server:** edit `GPU_HOSTS` in `monitoring/.env` (a comma-separated
list of `name:ip` pairs) and re-run `docker compose up -d`. No dashboard or Prometheus
config edits needed — `config-render` rewrites the file_sd targets and Prometheus hot-reloads.

## How config is built (the non-obvious part)

Prometheus and Alertmanager **cannot** read env vars in their config files (scrape targets,
SMTP blocks). So `monitoring/` has a **`config-render` init container** (busybox, runs once
before the main services via `depends_on: condition: service_completed_successfully`) that
expands `monitoring/.env` into a shared named volume (`rendered`):

- `GPU_HOSTS` → `prometheus/targets/{vllm,dcgm}.json` (Prometheus **file_sd** format, one
  target per host with its `server` label). `prometheus.yml` itself stays static and committed,
  pointing at these files via `file_sd_configs`.
- SMTP settings → `alertmanager.yml`, rendered from `alertmanager/alertmanager.tmpl.yml`
  (`__PLACEHOLDER__` tokens substituted by `sed` in `render/render.sh`).

The render logic lives in `monitoring/render/render.sh`. If you add a new `.env` variable that
must reach Prometheus/Alertmanager config, wire it through that script — not the YAML directly.

## Secrets

All secrets live **only** in `monitoring/.env` (git-ignored). The repo ships `monitoring/.env.example`
with placeholders. Mechanisms:

- **Grafana admin password** → `GF_ADMIN_PASSWORD`, read natively via compose env substitution.
- **SMTP password** → written by `render.sh` to a `smtp_password` file in the `rendered` volume and
  referenced via Alertmanager's `smtp_auth_password_file`, so it **never** appears in any committed
  or rendered YAML.
- The `agent/` stack has no secrets at all.

`.gitignore` excludes every `.env`, anything under `rendered/`, `*.swp`, and the `supertool`
symlink (a Claude Code plugin-cache artifact, not part of the deployment).

## Conventions & gotchas

- **Alert thresholds are hardware/consumer-tuned** (`monitoring/prometheus/alert_rules.yml`):
  latency warns at p95 > 6s / critical > 9s because the downstream rspamd GPT plugin times out at
  10s; GPU temp warns at 80C (3090 throttles ~83C); VRAM warns at 23 GiB (of the 3090's 24). All
  alert expressions aggregate `by (..., server)` so they fire per host and populate
  `{{ $labels.server }}` / the critical-email subject.
- **`metricName` prefixes:** vLLM metrics carry a `vllm:` prefix (e.g. `vllm:kv_cache_usage_perc`);
  GPU metrics use DCGM names (`DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_FB_USED`). The `server` label is
  attached at scrape time via file_sd, so it's present on both vLLM and DCGM series.
- **Reachability is the deploy-time dependency:** the monitoring host must reach each GPU host on
  `:8000` and `:9400`. Restrict those ports to the monitoring host (LAN/firewall); DCGM and
  Prometheus have no auth.
- **Ports are fixed** in the design: vLLM `:8000`, DCGM `:9400`. `GPU_HOSTS` entries are `name:ip`
  only — `render.sh` appends the ports.
