#!/bin/bash
# ip-connectivity.sh — Akeyless gateway firewall/connectivity test.
#
# Runs from inside the network segment that will host the Akeyless gateway and
# verifies that each service hostname, routed via --resolve to a given IP,
# terminates on the expected ingress and that non-443 TCP ports are reachable.
#
# Usage:
#   ./ip-connectivity.sh [-d <domain>] -e <label>:<ip>[,<ip>,...] [-e ...]
#
# Examples:
#   ./ip-connectivity.sh -d tenant.akeyless.io -e PROD:1.2.3.4,5.6.7.8
#   ./ip-connectivity.sh -e PROD:1.2.3.4 -e DEV:9.8.7.6

set -u

# ---------------------------------------------------------------- config
AKEYLESS_DOMAIN="akeyless.io"
CONNECT_TIMEOUT=2
MAX_TIME=5
MAX_PARALLEL=8

# Akeyless services on 443 tested via GET /status. Any HTTP response (200, 404,
# 400, 401, ...) means the request reached nginx, which is the connectivity
# signal. auth-cert and hvp are in this list too — the old bespoke checks for
# "mTLS Handshake" markers and JSON version strings were either false-positive
# prone or out of scope for a connectivity test.
akeyless_services=(
  console vault vault-ro auth auth-ro auth-cert audit audit-ro
  bis bis-ro gator gator-ro hvp rest
  kfm1 kfm1-ro kfm2 kfm2-ro kfm3 kfm3-ro kfm4 kfm4-ro
)

# Non-443 TCP ports. Format: "hostname:port" (hostname is relative to domain).
non_443_services=(
  "mq:5671"
  "log:9997"
  "log:9443"
)

# AWS endpoints (tested against real DNS, no IP override).
aws_services=(
  akeyless-cli.s3.us-east-2.amazonaws.com
  akeylessservices.s3.us-east-2.amazonaws.com
  sqs.us-east-2.amazonaws.com
)

# ---------------------------------------------------------------- styling
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  green=$'\033[1;32m'; orange=$'\033[1;33m'; red=$'\033[1;31m'; reset=$'\033[0m'
else
  green=""; orange=""; red=""; reset=""
fi

# ---------------------------------------------------------------- arg parsing
declare -a env_names=()
declare -a env_ip_lists=()

usage() {
  cat <<EOF
Usage: $0 [-d <domain>] -e <label>:<ip>[,<ip>,...] [-e ...]

  -d <domain>   Akeyless domain (default: akeyless.io).
                For single-tenant, give the full subdomain, e.g. tenant.akeyless.io.
  -e <env>      Environment label and IPs, e.g. DEV:1.2.3.4,5.6.7.8.
                May be repeated.
EOF
  exit 1
}

while getopts ":d:e:h" opt; do
  case $opt in
    d) AKEYLESS_DOMAIN="$OPTARG" ;;
    e)
      label="${OPTARG%%:*}"
      ips="${OPTARG#*:}"
      if [ -z "$label" ] || [ -z "$ips" ] || [ "$label" = "$OPTARG" ]; then
        echo "Error: -e requires format LABEL:ip1,ip2,..." >&2
        usage
      fi
      env_names+=("$label")
      env_ip_lists+=("$ips")
      ;;
    h|*) usage ;;
  esac
done

[ "${#env_names[@]}" -gt 0 ] || { echo "Error: at least one -e required." >&2; usage; }

# ---------------------------------------------------------------- helpers

# Classify a status string. Single source of truth for all pass/warn/fail
# decisions — used at render time only.
#   ok:   full reachability (any HTTP code 2xx/3xx/404, or raw TCP open for non-443 ports)
#   warn: reachable at a lower layer than HTTPS (TLS only, TCP only) or HTTP 4xx/5xx
#   fail: genuinely unreachable (TCP closed, no response at all)
classify() {
  case "$1" in
    2[0-9][0-9]|3[0-9][0-9]|404|"TCP open")       echo ok ;;
    4[0-9][0-9]|5[0-9][0-9]|"TLS only"|"TCP only") echo warn ;;
    *)                                             echo fail ;;
  esac
}

# Single curl wrapper. -k because we're testing connectivity, not PKI.
_curl() {
  curl -k --connect-timeout "$CONNECT_TIMEOUT" -m "$MAX_TIME" "$@"
}

# HTTPS check via --resolve. Prints one TAB-separated row:  env<TAB>endpoint<TAB>status
check_https() {
  local env="$1" ip="$2" hostname="$3" path="${4:-/status}" code
  code=$(_curl -s --resolve "$hostname:443:$ip" \
    -o /dev/null -w '%{http_code}' "https://$hostname$path" 2>/dev/null || true)
  printf '%s\t%s -> %s\t%s\n' "$env" "$hostname" "$ip" "${code:-000}"
}

# HTTPS check against real DNS (no --resolve). Used for AWS endpoints.
check_dns() {
  local env="$1" hostname="$2" code
  code=$(_curl -s -o /dev/null -w '%{http_code}' "https://$hostname" 2>/dev/null || true)
  printf '%s\t%s\t%s\n' "$env" "$hostname" "${code:-000}"
}

# TCP-connect check on an arbitrary port. We parse curl -v's "Connected to"
# marker, which is emitted the moment the 3-way handshake completes, before
# any protocol exchange — so it works regardless of whether the port serves
# HTTPS, AMQP, or anything else.
check_tcp() {
  local env="$1" ip="$2" hostname="$3" port="$4" output status
  output=$(curl -v -s --connect-timeout "$CONNECT_TIMEOUT" -m "$CONNECT_TIMEOUT" \
    "http://$ip:$port" 2>&1 || true)
  [[ "$output" == *"* Connected to "* ]] && status="TCP open" || status="000"
  printf '%s\t%s:%s -> %s\t%s\n' "$env" "$hostname" "$port" "$ip" "$status"
}

# Layered preflight: probe HTTPS → TLS → TCP and return which layer works.
# We do this by running one verbose curl and inspecting where it got.
#   HTTPS  — got a real HTTP response code; full sweep is worth running
#   TLS    — TLS handshake completed but no HTTP response (ingress misrouted, LB problem)
#   TCP    — TCP handshake completed but TLS didn't (port listens but not TLS-aware, or TLS down)
#   CLOSED — no handshake at all (firewall blocking or nothing listening)
# A key caveat: TCP/TLS open does NOT prove correct virtual-host routing is
# configured — only that something is listening at that layer.
probe_layer() {
  local ip="$1" hostname="${akeyless_services[0]}.$AKEYLESS_DOMAIN"
  local verbose code tmp
  tmp=$(mktemp)
  code=$(curl -vk -s --resolve "$hostname:443:$ip" -m 3 \
    -o /dev/null -w '%{http_code}' "https://$hostname/status" 2>"$tmp" || true)
  verbose=$(cat "$tmp")
  rm -f "$tmp"

  if [ -n "$code" ] && [ "$code" != "000" ]; then
    echo "HTTPS"
  elif echo "$verbose" | grep -qE 'SSL connection using|TLS handshake, Finished|ALPN: server accepted'; then
    echo "TLS"
  elif [[ "$verbose" == *"* Connected to "* ]]; then
    echo "TCP"
  else
    echo "CLOSED"
  fi
}

# Emit a layer-specific status row for every HTTPS service on an IP that
# didn't make it to the HTTPS layer. classify() maps TLS/TCP to "warn"
# (reachable at some layer) and CLOSED to "fail" (genuinely blocked).
bulk_fail() {
  local env="$1" ip="$2" layer="$3" status svc
  case "$layer" in
    TLS)    status="TLS only" ;;
    TCP)    status="TCP only" ;;
    CLOSED) status="TCP 443 closed" ;;
    *)      status="Unknown" ;;
  esac
  for svc in "${akeyless_services[@]}"; do
    printf '%s\t%s.%s -> %s\t%s\n' "$env" "$svc" "$AKEYLESS_DOMAIN" "$ip" "$status"
  done
}

# Full probe for one IP. Runs in a subshell; all result rows go to stdout,
# progress messages to stderr. Never touches global state — safe to parallelize.
probe_ip() {
  local env="$1" ip="$2" layer msg entry host port svc
  printf '%sTesting %s IP: %s%s\n' "$green" "$env" "$ip" "$reset" >&2

  layer=$(probe_layer "$ip")
  if [ "$layer" = "HTTPS" ]; then
    for svc in "${akeyless_services[@]}"; do
      check_https "$env" "$ip" "$svc.$AKEYLESS_DOMAIN"
    done
  else
    case "$layer" in
      TLS)    msg="TLS handshake works but no HTTPS response" ;;
      TCP)    msg="TCP open but TLS does not complete" ;;
      CLOSED) msg="TCP/443 closed" ;;
    esac
    printf '%s  %s: %s — skipping HTTPS sweep%s\n' "$red" "$ip" "$msg" "$reset" >&2
    bulk_fail "$env" "$ip" "$layer"
  fi

  for entry in "${non_443_services[@]}"; do
    host="${entry%:*}"
    port="${entry##*:}"
    check_tcp "$env" "$ip" "$host.$AKEYLESS_DOMAIN" "$port"
  done
}

# ---------------------------------------------------------------- main
printf '\n%sIP Connectivity Test (--resolve)%s\n' "$green" "$reset"
printf '%sDomain: %s%s\n\n' "$green" "$AKEYLESS_DOMAIN" "$reset"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Spawn one subshell per IP. Ordered tempfiles preserve output order despite
# parallel execution. Concurrency cap prevents opening hundreds of sockets
# when the caller passes a large IP list.
slot=0
order=()
for idx in "${!env_names[@]}"; do
  IFS=',' read -ra ips <<< "${env_ip_lists[$idx]}"
  for ip in "${ips[@]}"; do
    outfile=$(printf '%s/%04d' "$tmpdir" "$slot")
    order+=("$outfile")
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]; do sleep 0.1; done
    probe_ip "${env_names[$idx]}" "$ip" > "$outfile" &
    slot=$((slot + 1))
  done
done
wait

# AWS endpoints — serial, fast (one call each, real DNS).
aws_file="$tmpdir/zz_aws"
: > "$aws_file"
for host in "${aws_services[@]}"; do
  check_dns "AWS" "$host" >> "$aws_file"
done
order+=("$aws_file")

# ---------------------------------------------------------------- render
printf '\n%sConnectivity Check Results:%s\n' "$green" "$reset"
sep="--------------------------------------------------------------------------------------------------------------"
printf '%s\n' "$sep"
printf '%-10s  %-65s  %s\n' "ENV" "ENDPOINT" "STATUS"
printf '%s\n' "$sep"

fail_count=0
warn_count=0
declare -a fail_rows=()
declare -a warn_rows=()

while IFS=$'\t' read -r env endpoint status; do
  verdict=$(classify "$status")
  case "$verdict" in
    ok)   color="$green" ;;
    warn) color="$orange"; warn_count=$((warn_count + 1)); warn_rows+=("$endpoint -> $status") ;;
    fail) color="$red";    fail_count=$((fail_count + 1)); fail_rows+=("$endpoint -> $status") ;;
  esac
  printf '%s%-10s  %-65s  %s%s\n' "$color" "$env" "$endpoint" "$status" "$reset"
done < <(cat "${order[@]}")

printf '%s\n' "$sep"

if [ "$warn_count" -gt 0 ]; then
  printf '\n%sServices with warnings (reachable at a lower layer than HTTPS):%s\n' "$orange" "$reset"
  for r in "${warn_rows[@]}"; do printf '%s  - %s%s\n' "$orange" "$r" "$reset"; done
  printf '%s  Note: TCP/TLS open proves the port is listening; it does NOT prove the correct%s\n' "$orange" "$reset"
  printf '%s        virtual-host routing is configured for this hostname.%s\n' "$orange" "$reset"
fi

if [ "$fail_count" -gt 0 ]; then
  printf '\n%sServices that failed connectivity check:%s\n' "$red" "$reset"
  for r in "${fail_rows[@]}"; do printf '%s  - %s%s\n' "$red" "$r" "$reset"; done
  printf '\n%sAction required: open firewall / verify routing for the failed services.%s\n' "$red" "$reset"
  exit 1
fi

printf '\n%s[OK] All services reachable%s\n' "$green" "$reset"
exit 0
