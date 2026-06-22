# llm-monitoring documentation

Monitoring stack for a fleet of self-hosted LLM inference servers (vLLM and
llama.cpp), with consolidated Grafana dashboards and email alerting.

## Contents

- [architecture.md](architecture.md) — topology, data flow, design rationale, labels
- [deployment.md](deployment.md) — deploy runbook for both the agent and monitoring hosts
- [adding-a-server.md](adding-a-server.md) — register a new vLLM / llama.cpp / GPU host
- [alerts.md](alerts.md) — alert reference: what each alert means and what to do
- [troubleshooting.md](troubleshooting.md) — common problems and fixes

The original design spec lives in
[superpowers/specs/2026-06-22-monitoring-split-design.md](superpowers/specs/2026-06-22-monitoring-split-design.md).

## 60-second mental model

```
GPU servers (agent/)                         Monitoring host (monitoring/)
  vLLM       :8000/metrics  ──scrape──┐
  llama.cpp  :8080/metrics  ──scrape──┼──►   Prometheus ──► Alertmanager ──► email
  DCGM       :9400          ──scrape──┘          │
                                                 └──► Grafana (per-host dashboards)
```

- **Agents** are thin: each GPU host runs only the DCGM exporter. vLLM and
  llama.cpp expose their own `/metrics`.
- **The monitoring host** runs one central Prometheus that scrapes every host,
  plus Grafana and Alertmanager. All configuration is driven by `monitoring/.env`.
