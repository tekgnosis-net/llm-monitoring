# Alert reference

Alerts are defined in `monitoring/prometheus/alert_rules.yml`, evaluated by the
central Prometheus, and routed to email by Alertmanager. Every alert carries a
`server` label so it names the host that fired. `critical` alerts email
`ALERT_EMAIL_CRITICAL` quickly and re-notify hourly; `warning` alerts email
`ALERT_EMAIL_DEFAULT`.

Thresholds are tuned to the reference hardware (single RTX 3090) and a downstream
consumer (the rspamd GPT plugin, which times out at 10s). Adjust in
`alert_rules.yml` if your fleet differs.

## Tiers (interactive vs batch)

Generative hosts carry a `tier` label (`interactive` by default; `batch` if the
server name is listed in `BATCH_SERVERS` in `.env`). The tier gates **only** the
absolute-latency alerts:

- **e2e-latency and TTFT alerts fire for `tier="interactive"` only.** A batch /
  long-context host (e.g. Hindsight consolidation) has legitimately long prefills
  and would false-page on these, so it's exempt.
- **Everything else — queue depth, KV pressure, request failures, down, and the
  TPOT decode-speed alert — fires on every tier.** These are workload-agnostic.

For a *hybrid* endpoint (one model serving both interactive and batch traffic,
like a 3090 running rspamd + Hindsight), you can't separate the two in metrics,
so lean on TPOT + queue + KV as the real signals; tag it `interactive` only if
you want the absolute-latency pages and accept some consolidation noise, or
`batch` to silence them.

## vLLM (`vllm_serving`)

| Alert | Sev | Tier | Fires when | What to check |
|---|---|---|---|---|
| `VllmLatencyApproachingRspamdTimeout` | warning | interactive | p95 e2e latency > 6s for 2m | A long-context job hogging prefill, or sustained high concurrency |
| `VllmLatencyCritical` | critical | interactive | p95 e2e latency > 9s for 1m | rspamd GPT checks about to time out — reduce load now |
| `VllmHighTimeToFirstToken` | warning | interactive | TTFT p95 > 5s for 2m | A big prompt mid-prefill blocking short requests |
| `VllmDecodeSlow` | warning | all | TPOT p95 > 100ms for 3m | Decode degraded (contention/throttle/mem). **Tune to ~2× measured baseline** |
| `VllmRequestsQueueing` | warning | all | `num_requests_waiting` > 0 for 5m | Concurrency ceiling hit — raise `--max-num-seqs` or cap a client |
| `VllmKvCacheHigh` | warning | all | KV cache > 85% for 3m | Long-context requests filling the pool; preemption risk |
| `VllmRequestFailures` | warning | all | failures/sec > 0 for 1m | Engine logs: aborts, OOM, malformed requests |
| `VllmDown` | critical | all | `up{job="vllm"} == 0` for 1m | Server crashed/restarting, or unreachable from the monitoring host |

`VllmDecodeSlow` uses `vllm:time_per_output_token_seconds` (TPOT) — decode-bound,
so it's robust to prompt length and the right cross-hardware / hybrid-endpoint
signal. Measure your baseline before trusting the default threshold:
`histogram_quantile(0.95, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))`.

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
