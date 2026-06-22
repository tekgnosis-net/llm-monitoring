# Monitoring agent (per GPU server)

Runs the NVIDIA DCGM exporter so the central monitoring host can scrape this
server's GPU metrics. vLLM already exposes its own metrics on `:8000/metrics`,
so this is the only thing the GPU host needs to run for monitoring.

## Deploy

```bash
docker compose up -d
curl http://localhost:9400/metrics   # confirm GPU metrics are exported
```

## Register with the monitoring host

On the monitoring host, add this server to `GPU_HOSTS` in `monitoring/.env`:

```
GPU_HOSTS=...,thishost:<this-host-LAN-ip>
```

then `docker compose up -d` there to re-render the scrape targets.

## Requirements

- NVIDIA driver + `nvidia-container-toolkit` (`runtime: nvidia`).
- The monitoring host must be able to reach this host on `:9400` (DCGM) and
  `:8000` (vLLM). Open those ports to the monitoring host only (LAN/firewall).
