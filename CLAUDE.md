# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**llm-monitoring** — a Docker Compose monitoring deployment for a fleet of
self-hosted LLM inference servers (**vLLM** and **llama.cpp**). It contains
**no application source and no LLM server** — only configuration. The LLM servers
are deployed separately (per GPU host) and merely observed.

Two independently deployable units:

- **`agent/`** — runs on each GPU server. Just the NVIDIA **DCGM exporter** (`:9400`).
  vLLM exposes its own metrics on `:8000/metrics`; llama.cpp on `:8080/metrics`
  (needs `--metrics`). Stateless, secret-free.
- **`monitoring/`** — runs on one monitoring host. A **central Prometheus** scrapes
  every server's LLM endpoint + DCGM over the LAN, plus **Grafana** (consolidated
  per-host dashboards) and **Alertmanager** (email alerts).

Detailed docs are in [`docs/`](docs/); the design rationale (and the rejected
per-agent-Prometheus alternative) is in `docs/superpowers/specs/2026-06-22-monitoring-split-design.md`.

## Topology & labels

```
GPU servers (agent/)                    Monitoring host (monitoring/)
  vLLM      :8000/metrics  ─scrape─┐
  llama.cpp :8080/metrics  ─scrape─┼─►  Prometheus ─► alert_rules ─► Alertmanager ─► email
  DCGM      :9400          ─scrape─┘         └─► Grafana ($server dashboards)
```

Prometheus labels every target with `server=<name>` and (for LLM endpoints)
`backend=vllm|llamacpp`. These labels drive both the dashboard's per-host
repeating rows and the per-host alert annotations — they are load-bearing, not
cosmetic.

## Commands

No build/lint/test tooling — Docker Compose lifecycle + config validation.

```bash
# each GPU server:
cd agent && docker compose up -d && curl http://localhost:9400/metrics

# monitoring host:
cd monitoring && cp .env.example .env      # set *_HOSTS, GF_ADMIN_PASSWORD, SMTP_*
docker compose up -d
docker compose config                      # validate compose + .env substitution
docker compose logs config-render          # see the rendered host lists

# validate Prometheus rules/config after editing them:
docker run --rm --entrypoint promtool -v "$PWD/monitoring/prometheus:/p:ro" \
  prom/prometheus:latest check rules /p/alert_rules.yml
docker run --rm --entrypoint promtool -v "$PWD/monitoring/prometheus:/p:ro" \
  prom/prometheus:latest check config --syntax-only /p/prometheus.yml
```

Grafana `:3000` (LAN, password required); Prometheus `:9090` and Alertmanager
`:9093` are bound to `127.0.0.1` (tunnel or reverse-proxy to reach them).

**Adding/removing a server:** edit the `*_HOSTS` lists in `monitoring/.env` and
`docker compose up -d`. No dashboard or Prometheus edits — `config-render` rewrites
the file_sd targets and Prometheus hot-reloads. See `docs/adding-a-server.md`.

## How config is built (the non-obvious part)

Prometheus and Alertmanager can't read env vars in their config files. The
`monitoring/` stack has a **`config-render` busybox init container** (runs once
before the main services via `depends_on: condition: service_completed_successfully`)
that expands `monitoring/.env` into a shared volume (`monitoring/render/render.sh`):

- `VLLM_HOSTS` / `LLAMACPP_HOSTS` / `GPU_HOSTS` (each `name:ip[:port]`, comma-sep)
  → Prometheus **file_sd** target JSON, one per job, with `server`/`backend` labels.
  `prometheus.yml` is static and references these via `file_sd_configs`. An empty
  list renders `[]` (a job with no targets).
- SMTP settings → `alertmanager.yml` from `alertmanager/alertmanager.tmpl.yml`
  (`__PLACEHOLDER__` tokens substituted by `sed`).

If you add a new `.env` variable that must reach Prometheus/Alertmanager config,
wire it through `render.sh`, not the YAML directly.

## The dashboard

`monitoring/grafana/dashboards/llm-fleet.json` ("LLM serving fleet", uid `llm-fleet`).
Structure: a **Fleet Overview** stat row, then **per-backend sections whose rows
repeat once per server** (vLLM, llama.cpp, GPU). The repeat variables use
metric-scoped queries — `label_values(vllm:num_requests_running, server)`,
`label_values(llamacpp:requests_processing, server)`,
`label_values(DCGM_FI_DEV_GPU_TEMP, server)` — so each section only lists hosts
that actually run that backend (no empty rows).

It was produced by a generator script (not committed) for consistent structure.
To restructure it heavily, prefer editing in Grafana (provisioning has
`allowUiUpdates: true`) and exporting, or re-deriving from the panel patterns.

## Metric naming

- **vLLM** metrics are prefixed `vllm:` (e.g. `vllm:kv_cache_usage_perc`,
  `vllm:e2e_request_latency_seconds_bucket`). vLLM exposes request-latency/TTFT
  histograms.
- **llama.cpp** metrics are prefixed `llamacpp:` (e.g. `llamacpp:kv_cache_usage_ratio`,
  `llamacpp:requests_processing`, `llamacpp:requests_deferred`,
  `llamacpp:tokens_predicted_total`). llama.cpp exposes **no latency histogram**, so
  its dashboard section and alerts omit p95/TTFT — panels differ by what each backend emits.
- **GPU** metrics use DCGM names (`DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_FB_USED`).
  The `server` label is attached at scrape time via file_sd on all jobs.

## Secrets & exposure

All secrets live only in git-ignored `monitoring/.env` (repo ships `.env.example`):

- **Grafana admin password** → `GF_ADMIN_PASSWORD`, **required** — compose fails
  closed if unset (no `admin/admin` fallback).
- **SMTP password** → injected at runtime as a Docker **compose secret**
  (`environment: SMTP_PASSWORD` → `/run/secrets/smtp_password`, tmpfs); never
  rendered to disk or shared with Prometheus.
- Prometheus `:9090` / Alertmanager `:9093` are bound to `127.0.0.1` (unauthenticated
  admin UIs); Grafana `:3000` is LAN-exposed but password-gated.

`.gitignore` excludes every `.env`, anything under `rendered/`, `*.swp`, and the
`supertool` symlink. The repo has a staged-secret commit guard convention — never
commit a real `.env`.

## Conventions & gotchas

- **Alert thresholds are hardware/consumer-tuned** (`monitoring/prometheus/alert_rules.yml`):
  vLLM latency warns at p95 > 6s / critical > 9s (rspamd GPT plugin times out at 10s);
  GPU temp warns at 80C (3090 throttles ~83C); VRAM at 23 GiB (of 24). All alerts
  aggregate `by (..., server)` so they fire per host. Validate edits with `promtool`.
- **Reachability is the deploy-time dependency:** the monitoring host must reach each
  GPU host on `:8000`/`:8080`/`:9400`. Exporters have no auth — restrict via firewall.
- **Ports** default per backend (vLLM 8000, llama.cpp 8080, DCGM 9400); `*_HOSTS`
  entries may override with an optional `:port` field (DCGM is always 9400).
