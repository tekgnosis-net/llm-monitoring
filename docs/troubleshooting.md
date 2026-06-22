# Troubleshooting

## Grafana container won't start

`error ... required variable GF_ADMIN_PASSWORD is missing a value`

`GF_ADMIN_PASSWORD` is required (no insecure default). Set it in `monitoring/.env`
and `docker compose up -d`.

## A scrape target shows as DOWN in Prometheus

Check `http://localhost:9090/targets` (on the monitoring host). Common causes:

- **Firewall** — the monitoring host can't reach the GPU host on `:8000` / `:8080`
  / `:9400`. Open those ports to the monitoring host.
- **llama.cpp without `--metrics`** — `llama-server` only exposes `/metrics` when
  started with `--metrics`. Without it the endpoint 404s and the target is down.
- **Wrong port** — override per entry in `.env`, e.g. `gpu-d:192.168.1.53:8081`.
- **vLLM/llama.cpp not actually running** — `curl http://<host>:<port>/metrics`
  from the monitoring host to confirm.

## Dashboard sections are empty / a host is missing

The per-host rows come from `label_values(<metric>, server)`. A host only appears
once Prometheus has scraped at least one matching metric from it:

- vLLM rows need `vllm:*` metrics (host in `VLLM_HOSTS`, target up).
- llama.cpp rows need `llamacpp:*` metrics (host in `LLAMACPP_HOSTS`, `--metrics` on).
- GPU rows need `DCGM_*` metrics (host in `GPU_HOSTS`, agent running).

If a target is up but the row is missing, give it a scrape interval or two, then
refresh the dashboard variables (the picker has a refresh control).

## config-render fails

`config-render` exits non-zero if a referenced `.env` variable is unset. Check:

```bash
docker compose logs config-render
```

`SMTP_*` and `ALERT_EMAIL_*` must be present (host lists may be empty, not unset —
the example `.env` defines them all). Re-run `docker compose up -d` after fixing.

## Email alerts aren't arriving

- Confirm `SMTP_*` and `ALERT_EMAIL_*` in `.env`; re-run `docker compose up -d`.
- The SMTP password is a Docker secret at `/run/secrets/smtp_password` — verify it
  resolved: `docker compose exec alertmanager cat /run/secrets/smtp_password`.
- Check Alertmanager logs: `docker compose logs alertmanager` (TLS/auth errors).
- Port 587 + STARTTLS is assumed (`smtp_require_tls: true`). For implicit TLS use
  port 465 in `SMTP_SMARTHOST`.
- Fire a test by temporarily lowering a threshold, or inspect active alerts at the
  Alertmanager UI (`127.0.0.1:9093`, via tunnel).

## Can't open Prometheus or Alertmanager from another machine

They're bound to `127.0.0.1` on purpose (unauthenticated admin UIs). Options:

- SSH tunnel: `ssh -L 9090:localhost:9090 -L 9093:localhost:9093 <monitoring-host>`.
- Or change the published bind in `monitoring/docker-compose.yml` to expose on the
  LAN (and front with an authenticating reverse proxy if you do).

## DCGM exporter keeps restarting

Common on consumer cards / VFIO passthrough. GPU serving is unaffected — only
telemetry is lost. Check `docker compose logs` on the agent; ensure
`nvidia-container-toolkit` is installed and `nvidia-smi` works in a container.
