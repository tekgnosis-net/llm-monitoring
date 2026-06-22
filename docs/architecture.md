# Architecture

## Topology

Two independently deployable units:

| Unit | Runs on | Contains |
|---|---|---|
| `agent/` | each GPU server | NVIDIA DCGM exporter (`:9400`) |
| `monitoring/` | one monitoring host | Prometheus, Grafana, Alertmanager, a config-render init step |

vLLM and llama.cpp are **not** part of this repo — they are deployed
independently and merely observed. Each exposes its own Prometheus metrics
(vLLM on `:8000/metrics`; llama.cpp on `:8080/metrics`, requires `--metrics`).

## Data flow

```
                 ┌──────────────── monitoring host ────────────────┐
 vLLM :8000 ─────┤                                                  │
 llama :8080 ────┼─► Prometheus ──► alert_rules.yml ──► Alertmanager ──► email
 DCGM :9400 ─────┤        │                                         │
                 │        └─► Grafana (dashboards)                  │
                 └──────────────────────────────────────────────────┘
```

- Prometheus scrapes every endpoint every 5s and labels each target with
  `server=<name>` and (for LLM endpoints) `backend=vllm|llamacpp`.
- Alert rules are evaluated centrally; alerts route through Alertmanager to email.
- Grafana reads the single Prometheus datasource.

## Why centralized (thin agents)

A single Prometheus scraping stateless exporters is simpler than a Prometheus
per host: one datasource, one rules file, one retention setting, and dashboards
that can show or compare any host. The accepted trade-off is no edge buffering —
if the monitoring host is down, there's a gap in the metrics timeline. For a
private-LAN fleet that's acceptable (monitoring-host downtime stops alert
delivery regardless).

Full rationale and the rejected per-agent-Prometheus alternative:
[superpowers/specs/2026-06-22-monitoring-split-design.md](superpowers/specs/2026-06-22-monitoring-split-design.md).

## Labels

Every series carries a `server` label (the human name from the `*_HOSTS` lists).
LLM endpoints also carry `backend` (`vllm`/`llamacpp`) and `tier`
(`interactive`/`batch`, from `BATCH_SERVERS`). These drive:

- **Dashboards** — per-host repeating rows via `label_values(<metric>, server)`.
- **Alerts** — each fires per host and names it via `{{ $labels.server }}`; `tier`
  gates the interactive-only e2e/TTFT alerts, while decode-speed (TPOT), queue, and
  KV alerts apply to every tier (see [alerts.md](alerts.md)).

## Config rendering

Prometheus and Alertmanager cannot read environment variables in their config
files. A busybox **config-render** init container (runs once before the main
services) expands `monitoring/.env` into a shared volume:

- `VLLM_HOSTS` / `LLAMACPP_HOSTS` / `GPU_HOSTS` → Prometheus file_sd target JSON
  (each target labelled with `server` and `backend`). `prometheus.yml` itself is
  static and references these via `file_sd_configs`, so Prometheus hot-reloads
  target changes without a restart.
- SMTP settings → `alertmanager.yml` from `alertmanager.tmpl.yml`.

## Secrets

All secrets live only in git-ignored `monitoring/.env`:

- **Grafana admin password** — `GF_ADMIN_PASSWORD`, required (compose fails if unset).
- **SMTP password** — injected at runtime as a Docker **compose secret**
  (`/run/secrets/smtp_password`, tmpfs); never rendered to disk or shared with Prometheus.

## Network exposure

- Grafana `:3000` — the user-facing UI, published on all interfaces (password required).
- Prometheus `:9090` and Alertmanager `:9093` — **bound to `127.0.0.1`** (operator
  UIs; all internal traffic uses the compose network). Reach them via SSH tunnel
  or a reverse proxy; to expose on the LAN, change the published bind in
  `monitoring/docker-compose.yml`.
- Each GPU host must allow the monitoring host to reach `:8000`/`:8080`/`:9400`.
  These exporters have no authentication — restrict them with a host firewall.
