# Alert reference

Alerts are defined in `monitoring/prometheus/alert_rules.yml`, evaluated by the
central Prometheus, and routed to email by Alertmanager. Every alert carries a
`server` label so it names the host that fired. `critical` alerts email
`ALERT_EMAIL_CRITICAL` quickly and re-notify hourly; `warning` alerts email
`ALERT_EMAIL_DEFAULT`.

Thresholds are tuned to the reference hardware (single RTX 3090) and a downstream
consumer (the rspamd GPT plugin, which times out at 10s). Adjust in
`alert_rules.yml` if your fleet differs.

## vLLM (`vllm_serving`)

| Alert | Sev | Fires when | What to check |
|---|---|---|---|
| `VllmLatencyApproachingRspamdTimeout` | warning | p95 e2e latency > 6s for 2m | A long-context job hogging prefill, or sustained high concurrency |
| `VllmLatencyCritical` | critical | p95 e2e latency > 9s for 1m | rspamd GPT checks about to time out — reduce load now |
| `VllmHighTimeToFirstToken` | warning | TTFT p95 > 5s for 2m | A big prompt mid-prefill blocking short requests |
| `VllmRequestsQueueing` | warning | `num_requests_waiting` > 0 for 5m | Concurrency ceiling hit — raise `--max-num-seqs` or cap a client |
| `VllmKvCacheHigh` | warning | KV cache > 85% for 3m | Long-context requests filling the pool; preemption risk |
| `VllmRequestFailures` | warning | failures/sec > 0 for 1m | Engine logs: aborts, OOM, malformed requests |
| `VllmDown` | critical | `up{job="vllm"} == 0` for 1m | Server crashed/restarting, or unreachable from the monitoring host |

## llama.cpp (`llamacpp_serving`)

| Alert | Sev | Fires when | What to check |
|---|---|---|---|
| `LlamacppDown` | critical | `up{job="llamacpp"} == 0` for 1m | Crashed, or started without `--metrics`, or unreachable |
| `LlamacppKvCacheHigh` | warning | `kv_cache_usage_ratio` > 85% for 3m | Context near exhaustion; requests may defer/truncate |
| `LlamacppRequestsDeferred` | warning | `requests_deferred` > 0 for 5m | All slots busy — raise `--parallel`/slots or cap concurrency |

## GPU (`gpu_health`)

| Alert | Sev | Fires when | What to check |
|---|---|---|---|
| `GpuTemperatureHigh` | warning | GPU temp > 80C for 3m | Chassis airflow / fan curves (3090 throttles ~83C) |
| `GpuMemoryNearFull` | warning | VRAM > 23 GiB (of 24) for 3m | Unexpected over-allocation — investigate before OOM |
| `DcgmExporterDown` | warning | `up{job="dcgm-gpu"} == 0` for 2m | dcgm-exporter container (consumer-card/VFIO quirks); serving unaffected |

## Inhibition

When `VllmDown` fires for a server, its `warning`-level alerts (latency, queueing)
are suppressed for that **same** server, so a down host produces one alert rather
than a storm. Other healthy hosts are unaffected.

## Validating changes

After editing `alert_rules.yml`:

```bash
docker run --rm --entrypoint promtool -v "$PWD/monitoring/prometheus:/p:ro" \
  prom/prometheus:latest check rules /p/alert_rules.yml
```
