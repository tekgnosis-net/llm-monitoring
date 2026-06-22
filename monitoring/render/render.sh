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

# --- Prometheus file_sd targets from GPU_HOSTS ("name:ip,name:ip,...") -------
# vLLM metrics live on :8000, DCGM on :9400. Each target carries its server
# label so Grafana/alerts can tell hosts apart.
build_targets() {
  port="$1"; out="$2"
  printf '[\n' > "$out"
  first=1
  IFS=','
  for entry in $GPU_HOSTS; do
    name=${entry%%:*}
    ip=${entry#*:}
    [ "$first" -eq 1 ] || printf ',\n' >> "$out"
    first=0
    printf '  { "targets": ["%s:%s"], "labels": { "server": "%s" } }' "$ip" "$port" "$name" >> "$out"
  done
  unset IFS
  printf '\n]\n' >> "$out"
}
build_targets 8000 "$PROM_TARGETS/vllm.json"
build_targets 9400 "$PROM_TARGETS/dcgm.json"

# --- Alertmanager config -----------------------------------------------------
# The SMTP password goes to its own file (referenced via smtp_auth_password_file)
# so it never appears in YAML; only non-secret fields are substituted.
printf '%s' "$SMTP_PASSWORD" > "$AM_DIR/smtp_password"
sed \
  -e "s|__SMTP_SMARTHOST__|${SMTP_SMARTHOST}|g" \
  -e "s|__SMTP_FROM__|${SMTP_FROM}|g" \
  -e "s|__SMTP_USER__|${SMTP_USER}|g" \
  -e "s|__ALERT_EMAIL_DEFAULT__|${ALERT_EMAIL_DEFAULT}|g" \
  -e "s|__ALERT_EMAIL_CRITICAL__|${ALERT_EMAIL_CRITICAL}|g" \
  /templates/alertmanager.tmpl.yml > "$AM_DIR/alertmanager.yml"

echo "config-render: wrote targets for [$GPU_HOSTS] + alertmanager.yml"
