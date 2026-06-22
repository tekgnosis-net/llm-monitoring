#!/bin/sh
# ============================================================================
# config-render — expands monitoring/.env into the configs Prometheus and
# Alertmanager can't template themselves, writing into the shared volume.
# Runs once (busybox) before the main services start.
# ============================================================================
set -eu

SHARED=/etc/shared
PROM_TARGETS="$SHARED/prometheus/targets"
AM_DIR="$SHARED/alertmanager"
mkdir -p "$PROM_TARGETS" "$AM_DIR"

# Host lists may be unset/empty (e.g. a fleet with only one backend type).
VLLM_HOSTS="${VLLM_HOSTS:-}"
LLAMACPP_HOSTS="${LLAMACPP_HOSTS:-}"
GPU_HOSTS="${GPU_HOSTS:-}"

# --- Prometheus file_sd targets ---------------------------------------------
# Entries are "name:ip" or "name:ip:port". An empty list yields a valid empty
# JSON array, so the scrape job simply has no targets.
#
# build_llm <hosts> <default_port> <backend> <out>
build_llm() {
  hosts="$1"; default_port="$2"; backend="$3"; out="$4"
  printf '[\n' > "$out"
  first=1
  IFS=','
  for entry in $hosts; do
    [ -n "$entry" ] || continue
    name=$(printf '%s' "$entry" | cut -d: -f1)
    ip=$(printf '%s' "$entry" | cut -d: -f2)
    port=$(printf '%s' "$entry" | cut -d: -f3)
    [ -n "$port" ] || port="$default_port"
    [ "$first" -eq 1 ] || printf ',\n' >> "$out"
    first=0
    printf '  { "targets": ["%s:%s"], "labels": { "server": "%s", "backend": "%s" } }' \
      "$ip" "$port" "$name" "$backend" >> "$out"
  done
  unset IFS
  printf '\n]\n' >> "$out"
}

# build_dcgm <hosts> <out>   (GPU telemetry — server label only, fixed :9400)
build_dcgm() {
  hosts="$1"; out="$2"
  printf '[\n' > "$out"
  first=1
  IFS=','
  for entry in $hosts; do
    [ -n "$entry" ] || continue
    name=$(printf '%s' "$entry" | cut -d: -f1)
    ip=$(printf '%s' "$entry" | cut -d: -f2)
    [ "$first" -eq 1 ] || printf ',\n' >> "$out"
    first=0
    printf '  { "targets": ["%s:9400"], "labels": { "server": "%s" } }' "$ip" "$name" >> "$out"
  done
  unset IFS
  printf '\n]\n' >> "$out"
}

build_llm  "$VLLM_HOSTS"     8000 vllm     "$PROM_TARGETS/vllm.json"
build_llm  "$LLAMACPP_HOSTS" 8080 llamacpp "$PROM_TARGETS/llamacpp.json"
build_dcgm "$GPU_HOSTS"           "$PROM_TARGETS/dcgm.json"

# --- Alertmanager config -----------------------------------------------------
# Only non-secret fields are substituted here. The SMTP password is injected at
# runtime as a Docker secret (mounted at /run/secrets/smtp_password by compose),
# so it never passes through this render step or the persisted volume.
sed \
  -e "s|__SMTP_SMARTHOST__|${SMTP_SMARTHOST}|g" \
  -e "s|__SMTP_FROM__|${SMTP_FROM}|g" \
  -e "s|__SMTP_USER__|${SMTP_USER}|g" \
  -e "s|__ALERT_EMAIL_DEFAULT__|${ALERT_EMAIL_DEFAULT}|g" \
  -e "s|__ALERT_EMAIL_CRITICAL__|${ALERT_EMAIL_CRITICAL}|g" \
  /templates/alertmanager.tmpl.yml > "$AM_DIR/alertmanager.yml"

echo "config-render: vllm=[$VLLM_HOSTS] llamacpp=[$LLAMACPP_HOSTS] gpu=[$GPU_HOSTS] + alertmanager.yml"
