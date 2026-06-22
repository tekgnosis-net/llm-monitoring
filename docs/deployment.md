# Deployment runbook

Two parts: a thin **agent** on each GPU server, and the **monitoring** stack on
one dedicated host. Deploy agents first (so their exporters exist), then the
monitoring host.

## Prerequisites

- Docker + Docker Compose v2 on all hosts.
- On GPU hosts: NVIDIA driver + `nvidia-container-toolkit` (for `runtime: nvidia`).
- vLLM started normally (exposes `/metrics` on `:8000`).
- llama.cpp started with `--metrics` (exposes `/metrics`, default `:8080`).
- Network: the monitoring host must reach each GPU host on `:8000` (vLLM),
  `:8080` (llama.cpp), and `:9400` (DCGM).

## 1. Agent — on each GPU server

```bash
cd agent
docker compose up -d
curl http://localhost:9400/metrics    # confirm DCGM metrics
```

That's the entire agent. It's stateless and secret-free.

## 2. Monitoring host

```bash
cd monitoring
cp .env.example .env
$EDITOR .env            # set *_HOSTS (+ optional BATCH_SERVERS), GF_ADMIN_PASSWORD, SMTP_*
docker compose up -d
```

`.env` keys:

| Key | Meaning |
|---|---|
| `VLLM_HOSTS` | `name:ip[:port]` list of vLLM endpoints (port default 8000) |
| `LLAMACPP_HOSTS` | `name:ip[:port]` list of llama.cpp endpoints (port default 8080) |
| `GPU_HOSTS` | `name:ip` list of all GPU hosts running the DCGM agent |
| `BATCH_SERVERS` | optional: server names to mark `tier=batch` (exempt from the interactive e2e/TTFT alerts) |
| `GF_ADMIN_PASSWORD` | Grafana admin password (**required** — no default) |
| `SMTP_*`, `ALERT_EMAIL_*` | Alertmanager email delivery |

Leave a list empty if a backend isn't used; its scrape job will simply have no targets.

## 3. Verify

```bash
docker compose logs config-render        # shows the rendered host lists
curl -s localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c   # all "up"?
```

- **Grafana:** `http://<monitoring-host>:3000` (admin / your `GF_ADMIN_PASSWORD`).
  The "LLM serving fleet" dashboard auto-loads, datasource pre-wired.
- **Prometheus / Alertmanager:** bound to `127.0.0.1` — from the monitoring host use
  `http://localhost:9090` / `:9093`, or tunnel: `ssh -L 9090:localhost:9090 <host>`.

## Applying changes

Config files are rendered from `.env` at start by the `config-render` init step.
After editing `.env` (e.g. adding a server) or any config:

```bash
docker compose up -d          # re-runs config-render, re-renders, restarts what changed
```

Prometheus hot-reloads file_sd targets, so adding/removing a server doesn't even
need a Prometheus restart.
