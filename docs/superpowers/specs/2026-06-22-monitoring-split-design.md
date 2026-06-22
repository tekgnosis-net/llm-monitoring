# Design: Split vLLM monitoring into thin agents + a central monitoring stack

- **Date:** 2026-06-22
- **Status:** Approved (pending written-spec review)
- **Repo:** vllm-gpt (Docker Compose deployment, not a vLLM source fork)

## Context

The repo currently ships a single `docker-compose.yml` that runs everything on one host:
the vLLM server (`openai/gpt-oss-20b`) plus a full monitoring stack (Prometheus, Grafana,
Alertmanager, NVIDIA DCGM exporter). That only works when monitoring is co-located with the
single GPU server.

The deployment is moving to multiple GPU servers (each running vLLM independently, outside this
repo) with a **separate** host providing a consolidated monitoring UI. The repo must therefore
produce two independently deployable units, and must stop carrying vLLM-serving artifacts.

A secondary driver: secrets (an HF token, an SMTP password) were previously committed in plaintext.
The new layout must keep all secrets in git-ignored `.env` files only.

## Decision

Adopt a **centralized Prometheus** topology with **thin, stateless agents**:

- **Agents** (one per GPU server) run only the **DCGM exporter**. vLLM already exposes
  `/metrics` on `:8000` itself, so no per-agent Prometheus is needed.
- A **single central Prometheus** on the monitoring host scrapes every GPU server's vLLM
  (`:8000`) and DCGM (`:9400`) directly over the LAN, tagging each target with a `server` label.
- **Grafana** and **Alertmanager** live alongside the central Prometheus on the monitoring host.

### Why this over per-agent Prometheus (the earlier A1 candidate)

- Agents become trivial (one stateless exporter, no config, no secrets, no local storage).
- A single Prometheus = one datasource, one alert-rules file, one retention setting.
- Better dashboards: a `label_values(server)` template variable gives the desired per-server
  dropdown **and** an "All" overlay across servers — which multi-datasource A1 could not do cleanly.

### Accepted trade-off

No edge buffering: if the monitoring host is down, there is a gap in the metrics timeline for all
servers (agents don't store locally). Acceptable for a private-LAN deployment — and monitoring-host
downtime already means alerts can't be delivered regardless.

## Architecture

```
GPU server A                 GPU server B                 Monitoring host
┌──────────────┐             ┌──────────────┐             ┌───────────────────────────┐
│ vLLM  :8000  │◄──────┐     │ vLLM  :8000  │◄──────┐     │ Prometheus :9090           │
│ (separate)   │       │     │ (separate)   │       │     │  scrapes each host's       │
│              │       └─────┼──────────────┼───────┼─────┤  :8000 + :9400, labels by  │
│ dcgm  :9400  │◄────────────┘ dcgm  :9400  │◄──────┘     │  server=<name>             │
│ (agent/)     │             │ (agent/)     │             │     │                       │
└──────────────┘             └──────────────┘             │ Grafana :3000 (1 datasource│
                                                          │   $server dropdown)        │
                                                          │ Alertmanager :9093 (email) │
                                                          └───────────────────────────┘
```

Data flow: vLLM + DCGM exporters (edge) → central Prometheus (scrape every 5s, `server`-labeled,
15d retention) → `alert_rules.yml` → local Alertmanager → email.

## Repo layout

```
vllm-gpt/
├── agent/                          # deploy on each GPU server
│   ├── docker-compose.yml          #   dcgm-exporter only
│   └── README.md                   #   one-liner: docker compose up -d, publishes :9400
├── monitoring/                     # deploy on the monitoring host
│   ├── docker-compose.yml          #   config-render init + prometheus + grafana + alertmanager
│   ├── .env.example                #   GPU_HOSTS, GF_ADMIN_PASSWORD, SMTP_*, ALERT_EMAIL_*
│   ├── prometheus/
│   │   ├── prometheus.yml          #   static; jobs use file_sd_configs -> rendered targets
│   │   └── alert_rules.yml         #   existing vllm_serving + gpu_health rules (logic unchanged)
│   ├── alertmanager/
│   │   └── alertmanager.tmpl.yml   #   SMTP + recipients + password substituted from .env at start
│   ├── grafana/
│   │   ├── provisioning/datasources/prometheus.yml   # single local Prometheus datasource
│   │   ├── provisioning/dashboards/dashboards.yml
│   │   └── dashboards/vllm.json    #   + $server label-query template variable
│   └── render/                     #   render script(s) run by the init step
├── CLAUDE.md                       # rewritten for the two-stack split
├── .gitignore                      # .env, rendered configs, *.swp, supertool
└── docs/superpowers/specs/2026-06-22-monitoring-split-design.md
```

## Component specs

### Agent stack (`agent/docker-compose.yml`)
- Single service `dcgm-exporter` (`nvidia/dcgm-exporter:latest`), `runtime: nvidia`, GPU device
  reservation `[gpu, utility]`, `cap_add: SYS_ADMIN`, `restart: unless-stopped`, publishes `:9400`.
- No `.env`, no secrets, no templating. Safe to commit verbatim.
- vLLM is NOT managed here; it must already publish `:8000` on the host, reachable from the
  monitoring host.

### Monitoring stack (`monitoring/docker-compose.yml`)
- **`config-render`** (busybox init, `restart: "no"`): reads `.env`, writes rendered configs into a
  shared named volume, then exits. Main services `depends_on` it with
  `condition: service_completed_successfully`. It produces:
  - `targets/vllm.json` and `targets/dcgm.json` — file_sd target lists built by iterating
    `GPU_HOSTS` (`name:ip,name:ip,...`), each target carrying its `server` label.
  - `alertmanager.yml` — `alertmanager.tmpl.yml` with `${SMTP_*}` / `${ALERT_EMAIL_*}` placeholders
    substituted from `.env`.
- **`prometheus`** — static `prometheus.yml`; two jobs (`vllm` -> `:8000/metrics`, `dcgm-gpu` ->
  `:9400`) using `file_sd_configs` over the rendered target files; `alerting` -> `alertmanager:9093`;
  loads `alert_rules.yml`; `--storage.tsdb.retention.time=15d`; publishes `:9090`.
- **`grafana`** — `GF_SECURITY_ADMIN_PASSWORD=${GF_ADMIN_PASSWORD}`; single Prometheus datasource
  (`http://prometheus:9090`); dashboard `vllm.json` gains a `$server` template variable
  (`label_values(server)`) and panels filter by `{server=~"$server"}` (so "All" overlays everyone).
- **`alertmanager`** — mounts the rendered `alertmanager.yml`; routes to email; publishes `:9093`.
  Cross-host alerting from agents is gone (Prometheus and Alertmanager are co-located).

### `monitoring/.env.example`
```
# GPU servers to monitor: name:ip pairs, comma-separated. Add a server = add a pair.
GPU_HOSTS=gpu-a:192.168.1.50,gpu-b:192.168.1.51
# Grafana
GF_ADMIN_PASSWORD=changeme
# Alertmanager SMTP (mailcow)
SMTP_SMARTHOST=mail.example.net:587
SMTP_FROM=alerts@example.net
SMTP_USER=alerts@example.net
SMTP_PASSWORD=changeme
ALERT_EMAIL_DEFAULT=ops@example.net
ALERT_EMAIL_CRITICAL=admin@example.net
```

## Secret & config handling

- **Secrets live only in git-ignored `monitoring/.env`.** Repo ships `monitoring/.env.example` with
  placeholders. Agents have no secrets at all.
- **Env-native (no templating):** Grafana admin password; Grafana datasource URL is the internal
  `prometheus:9090` (no secret).
- **Render-at-start (for files that can't read env):** Prometheus scrape targets (via file_sd JSON
  rendered from `GPU_HOSTS`) and Alertmanager SMTP config (rendered from `.tmpl.yml`). Rendering is
  done by the busybox `config-render` init step into a shared volume. Rendered files are git-ignored.
- **Why templating at all:** Prometheus and Alertmanager intentionally do not interpolate env vars
  into scrape targets / SMTP blocks, so the ecosystem norm is to render config at deploy time.

## Alert rule changes

`alert_rules.yml` logic is unchanged. Because every target now carries a `server` label, firing
alerts automatically include it; the critical-email subject template adds
`{{ .CommonLabels.server }}` so the alert says which host fired. `up{job="vllm"}` / `up{job="dcgm-gpu"}`
down-detection still works per target.

## Cleanup (removed from this repo)

The following are vLLM-serving artifacts that belong with the (separate) vLLM deployment, not the
monitoring repo, and are removed: the `vllm` service, `HF_TOKEN` / the old root `.env`, the
`docker-compose.yml.1/.2/.3` snapshots, and `encodings/*.tiktoken`.

## Git plan

The working tree still contains the old plaintext secrets, so git stays uninitialized until the
restructure is complete and secrets are confined to git-ignored `.env` files. Then: `git init`,
confirm `git status` shows no `.env` or rendered configs, make the first clean commit (including
this spec), and recreate the private remote.

## Non-goals

- No HA/federation/remote_write (single-node monitoring host is fine for this scale).
- No auth/TLS on the DCGM exporter or Prometheus (private LAN; firewall is the boundary).
- No change to how vLLM itself is deployed or tuned — this repo only observes it.
