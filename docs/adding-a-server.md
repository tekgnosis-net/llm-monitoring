# Adding (or removing) a server

All fleet membership is driven by the `*_HOSTS` lists in `monitoring/.env`.
Entries are `name:ip` or `name:ip:port`; `name` becomes the `server` label shown
in dashboards and alerts.

## Add a GPU host running vLLM

1. **On the GPU host** — start the agent so DCGM is exported:
   ```bash
   cd agent && docker compose up -d
   ```
   Ensure vLLM is running and its `:8000` is reachable from the monitoring host.

2. **On the monitoring host** — append the host to the relevant lists in `.env`:
   ```
   VLLM_HOSTS=...,gpu-e:192.168.1.54
   GPU_HOSTS=...,gpu-e:192.168.1.54
   ```
   then re-render:
   ```bash
   cd monitoring && docker compose up -d
   ```

The new host appears automatically as a repeating row in the dashboard (the
`$vllm_server` / `$gpu_server` variables are populated from the live metrics).

## Add a GPU host running llama.cpp

Same as above, but use `LLAMACPP_HOSTS`. Start `llama-server` with `--metrics`.
Override the port if it isn't 8080:

```
LLAMACPP_HOSTS=...,gpu-f:192.168.1.55:8081
GPU_HOSTS=...,gpu-f:192.168.1.55
```

## A host running both backends

List it in both `VLLM_HOSTS` and `LLAMACPP_HOSTS` (the ports differ, so the two
endpoints are distinct). It will show up in both the vLLM and llama.cpp sections.

## Remove a host

Delete its entry from the relevant `*_HOSTS` lists and `docker compose up -d`.
Its dashboard rows disappear once its metrics age out; old time-series remain in
Prometheus until retention (15d) expires.

## Notes

- `GPU_HOSTS` is the set of hosts running the DCGM agent — usually the union of
  the LLM hosts. A host can be in `GPU_HOSTS` without serving any LLM (GPU-only
  telemetry) and vice-versa.
- Ports are per-backend defaults (vLLM 8000, llama.cpp 8080, DCGM 9400) unless
  overridden with the optional `:port` field (DCGM is always 9400).
