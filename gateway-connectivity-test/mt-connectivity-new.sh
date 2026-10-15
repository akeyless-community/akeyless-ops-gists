#!/bin/bash
# run this script from any node / machine inside the network you will be using
# to deploy the Akeyless gateway
# This variant tests connectivity by resolving Akeyless hostnames to specific IPs
# using curl --resolve, bypassing DNS to validate IP-level routing. If no IPs
# are supplied, the script falls back to normal DNS resolution so you can test
# multi-tenant or any reachable tenant by domain alone.
#
# Usage:
#   ./mt-connectivity.sh [-d <domain>] [-e <label>:<ip>[,<ip>,...]] [-e ...]
#
# Examples:
#   # Multi-tenant via DNS (default domain akeyless.io, no IPs needed):
#   ./mt-connectivity.sh
#
#   # Specific tenant via DNS:
#   ./mt-connectivity.sh -d tenant.akeyless.io
#
#   # Single-tenant with dev and prod IPs (IP-level routing):
#   ./mt-connectivity.sh -d tenant.akeyless.io \
#     -e DEV:10.0.0.1,10.0.0.2 \
#     -e PROD:10.1.0.1,10.1.0.2,10.1.0.3
#
#   # Multi-tenant with specific IPs:
#   ./mt-connectivity.sh -e PROD:1.2.3.4,5.6.7.8

set -uo pipefail

# Defaults
CONNECT_TIMEOUT=5
MAX_TIME=10

# Parse multiple -d domains and -e environment IP groups
declare -a domains=()
declare -a env_names=()
declare -a env_ip_lists=()

usage() {
  echo "Usage: $0 [-d <domain>] [-d <domain>] ... [-e <label>:<ip>[,<ip>,...]] [-e ...]"
  echo ""
  echo "  -d <domain>   Akeyless domain (default: akeyless.io)"
  echo "                For single-tenant, provide the full subdomain, e.g. tenant.akeyless.io"
  echo "                Can be specified multiple times to test several tenants in one run."
  echo "  -e <env>      Environment label and IPs, e.g. DEV:20.7.137.84,52.189.98.155"
  echo "                Can be specified multiple times for different environments."
  echo "                If omitted, the script tests via DNS resolution only."
  exit 1
}

while getopts ":d:e:h" opt; do
  case $opt in
    d) domains+=("$OPTARG") ;;
    e)
      label="${OPTARG%%:*}"
      ips_csv="${OPTARG#*:}"
      if [ -z "$label" ] || [ -z "$ips_csv" ] || [ "$label" = "$OPTARG" ]; then
        echo "Error: -e requires format LABEL:ip1,ip2,..." >&2
        usage
      fi
      env_names+=("$label")
      env_ip_lists+=("$ips_csv")
      ;;
    h) usage ;;
    *) usage ;;
  esac
done

# If no -d flags were given, default to multi-tenant.
if [ ${#domains[@]} -eq 0 ]; then
  domains=("akeyless.io")
fi

# If no -e flags were given, default to a single DNS-only pass using the domain.
if [ ${#env_names[@]} -eq 0 ]; then
  env_names+=("DNS")
  env_ip_lists+=("")
fi

# Akeyless services with /status endpoint (port 443)
akeyless_services=(
  console vault vault-ro auth auth-ro audit audit-ro
  bis bis-ro gator gator-ro kfm1 kfm1-ro kfm2 kfm2-ro kfm3 kfm3-ro
  kfm4 kfm4-ro rest
)

# Other Akeyless services (port 443, special checks)
other_443_services=(
  auth-cert
  hvp
)

# Non-443 services: name:hostname:port
non_443_services=(
  "mq:mq:5671"
  "log-9997:log:9997"
  "log-9443:log:9443"
)

# AWS endpoints (tested via DNS, not IPs)
aws_services=(
  akeyless-cli.s3.us-east-2.amazonaws.com
  akeylessservices.s3.us-east-2.amazonaws.com
  sqs.us-east-2.amazonaws.com
)

# Color codes
green="\033[1;32m"
orange="\033[1;33m"
red="\033[1;31m"
reset="\033[0m"

# Arrays to store results
env_labels=()
endpoints=()
statuses=()
failed_endpoints=()
failed_statuses=()
warning_endpoints=()
warning_statuses=()
has_failures=false
has_warnings=false

# Helper function for curl with timeouts
curl_with_timeout() {
  curl --connect-timeout "$CONNECT_TIMEOUT" -m "$MAX_TIME" "$@"
}

# Test a curl probe and record result. If ip is empty, DNS is used directly
# (no --resolve override); otherwise curl is forced to the given IP.
# Usage: test_resolve <env> <display_endpoint> <hostname> <port> <ip> <url> [extra_curl_args...]
test_resolve() {
  local env="$1" display="$2" hostname="$3" port="$4" ip="$5" url="$6"
  shift 6

  env_labels+=("$env")
  endpoints+=("$display")

  local resolve_args=()
  if [ -n "$ip" ]; then
    resolve_args=(--resolve "$hostname:$port:$ip")
  fi

  local status
  status=$(curl_with_timeout -s ${resolve_args[@]+"${resolve_args[@]}"} -o /dev/null -w "%{http_code}" "$url" "$@" 2>/dev/null) || true
  status="${status:-000}"
  statuses+=("$status")

  if [ "$status" = "200" ]; then
    : # success
  elif [ "$status" = "404" ]; then
    has_warnings=true
    warning_endpoints+=("$display")
    warning_statuses+=("$status (routed but no match)")
  else
    has_failures=true
    failed_endpoints+=("$display")
    failed_statuses+=("$status")
  fi
}

# ==============================================================================
# Test Akeyless services against all IPs (or DNS if no IPs provided)
# ==============================================================================
test_env_ips() {
  local env="$1"
  shift
  local ips=("$@")

  # Empty IP list => single DNS-only pass
  if [ ${#ips[@]} -eq 0 ]; then
    ips=("")
  fi

  for ip in "${ips[@]}"; do
    local suffix=""
    if [ -n "$ip" ]; then
      echo -e "${green}Testing $env IPs: $ip${reset}" >&2
      suffix=" → $ip"
    else
      echo -e "${green}Testing $env via DNS ($AKEYLESS_DOMAIN)${reset}" >&2
    fi

    # Services with /status
    for svc in "${akeyless_services[@]}"; do
      hostname="$svc.$AKEYLESS_DOMAIN"
      test_resolve "$env" "$hostname$suffix" "$hostname" 443 "$ip" "https://$hostname/status"
    done

    # auth-cert (mTLS handshake check)
    hostname="auth-cert.$AKEYLESS_DOMAIN"
    display="$hostname$suffix"
    env_labels+=("$env")
    endpoints+=("$display")
    resolve_args=()
    [ -n "$ip" ] && resolve_args=(--resolve "$hostname:443:$ip")
    curl_output=$(curl_with_timeout -vs ${resolve_args[@]+"${resolve_args[@]}"} "https://$hostname" 2>&1 || true)
    if echo "$curl_output" | grep -qE "(SSL certificate|server certificate|TLS handshake)"; then
      statuses+=("mTLS Handshake")
    else
      http_code=$(echo "$curl_output" | grep -oE "HTTP/[0-9.]+ [0-9]+" | tail -1 | awk '{print $2}')
      if [ -n "$http_code" ]; then
        statuses+=("$http_code (no mTLS)")
        has_warnings=true
        warning_endpoints+=("$display")
        warning_statuses+=("$http_code (reachable, no mTLS)")
      else
        statuses+=("Connection Failed")
        has_failures=true
        failed_endpoints+=("$display")
        failed_statuses+=("Connection Failed")
      fi
    fi

    # hvp (Vault proxy health check)
    hostname="hvp.$AKEYLESS_DOMAIN"
    endpoint="$hostname/v1/sys/health$suffix"
    env_labels+=("$env")
    endpoints+=("$endpoint")
    resolve_args=()
    [ -n "$ip" ] && resolve_args=(--resolve "$hostname:443:$ip")
    response=$(curl_with_timeout -s ${resolve_args[@]+"${resolve_args[@]}"} "https://$hostname/v1/sys/health" 2>/dev/null || true)
    if echo "$response" | grep -q '"version":"akeyless-hvp'; then
      statuses+=("akeyless-hvp")
    else
      status=$(curl_with_timeout -s ${resolve_args[@]+"${resolve_args[@]}"} -o /dev/null -w "%{http_code}" "https://$hostname/v1/sys/health" 2>/dev/null)
      status=${status:-000}
      statuses+=("$status")
      if [ "$status" = "200" ]; then
        : # success
      else
        has_failures=true
        failed_endpoints+=("$endpoint")
        failed_statuses+=("$status")
      fi
    fi

    # Non-443 services (mq:5671, log:9997, log:9443)
    for entry in "${non_443_services[@]}"; do
      IFS=: read -r label host port <<< "$entry"
      hostname="$host.$AKEYLESS_DOMAIN"
      display="$hostname:$port$suffix"
      env_labels+=("$env")
      endpoints+=("$display")

      resolve_args=()
      [ -n "$ip" ] && resolve_args=(--resolve "$hostname:$port:$ip")
      curl_output=$(curl -v --http0.9 ${resolve_args[@]+"${resolve_args[@]}"} --connect-timeout 3 --max-time 3 "https://$hostname:$port" 2>&1 || true)
      connected_line=$(echo "$curl_output" | grep -oE "Connected to [^ ]+ \([0-9.]+\) port [0-9]+" || true)
      if [ -n "$connected_line" ]; then
        conn_ip=$(echo "$connected_line" | grep -oE '\([0-9.]+\)' | tr -d '()')
        conn_port=$(echo "$connected_line" | grep -oE 'port [0-9]+' | awk '{print $2}')
        statuses+=("TCP Connected ($conn_ip:$conn_port)")
      else
        statuses+=("TCP Connection Failed")
        has_failures=true
        failed_endpoints+=("$display")
        failed_statuses+=("TCP Connection Failed on port $port")
      fi
    done
  done
}

echo -e "\n${green}=== Akeyless Connectivity Test ===${reset}"
echo -e "${green}Domains: ${domains[*]}${reset}"
if [ "${env_names[0]}" = "DNS" ] && [ -z "${env_ip_lists[0]}" ]; then
  echo -e "${green}Mode:    DNS resolution (no -e IPs supplied)${reset}\n"
else
  echo -e "${green}Mode:    IP routing via curl --resolve${reset}\n"
fi

for AKEYLESS_DOMAIN in "${domains[@]}"; do
  echo -e "${green}--- Domain: $AKEYLESS_DOMAIN ---${reset}" >&2
  for idx in "${!env_names[@]}"; do
    ips=()
    if [ -n "${env_ip_lists[$idx]}" ]; then
      IFS=',' read -ra ips <<< "${env_ip_lists[$idx]}"
    fi
    test_env_ips "${env_names[$idx]}" ${ips[@]+"${ips[@]}"}
  done
done

# ==============================================================================
# Test AWS endpoints (DNS-based, no IP override)
# ==============================================================================
for s in "${aws_services[@]}"; do
  endpoint="$s"
  endpoints+=("$endpoint")
  env_labels+=("AWS")

  if [ "$s" = "sqs.us-east-2.amazonaws.com" ]; then
    response=$(curl_with_timeout -s -X POST "https://$s" -d "Action=ListQueues&Version=2012-11-05" 2>/dev/null || true)
    if echo "$response" | grep -q '<Code>AccessDenied</Code>'; then
      statuses+=("Access Denied (reachable)")
      has_warnings=true
      warning_endpoints+=("$endpoint")
      warning_statuses+=("Access Denied (reachable)")
    elif echo "$response" | grep -qE '<ListQueuesResponse|<ListQueuesResult>'; then
      statuses+=("200")
    else
      status=$(curl_with_timeout -sIL -o /dev/null -w "%{http_code}" "https://$s" 2>/dev/null) ; status=${status:-000}
      statuses+=("Error ($status)")
      has_failures=true
      failed_endpoints+=("$endpoint")
      failed_statuses+=("Error ($status)")
    fi
  else
    # S3 buckets
    status=$(curl_with_timeout -sIL -o /dev/null -w "%{http_code}" "https://$s" 2>/dev/null) ; status=${status:-000}
    statuses+=("$status")
    if [ "$status" = "200" ]; then
      : # Success
    elif [ "$status" = "403" ]; then
      has_warnings=true
      warning_endpoints+=("$endpoint")
      warning_statuses+=("$status (reachable)")
    else
      has_failures=true
      failed_endpoints+=("$endpoint")
      failed_statuses+=("$status")
    fi
  fi
done

# ==============================================================================
# Print results
# ==============================================================================
echo -e "\n${green}Connectivity Check Results:${reset}"
echo "--------------------------------------------------------------------------------------------------------------"
printf "%-10s  %-65s  %s\n" "ENV" "ENDPOINT" "STATUS"
echo "--------------------------------------------------------------------------------------------------------------"
for i in "${!endpoints[@]}"; do
  endpoint="${endpoints[$i]}"
  status="${statuses[$i]}"
  env="${env_labels[$i]}"
  if [ "$status" = "200" ] || [ "$status" = "mTLS Handshake" ] || [ "$status" = "akeyless-hvp" ] || [[ "$status" == "TCP Connected"* ]]; then
    printf "${green}%-10s  %-65s  %s${reset}\n" "$env" "$endpoint" "$status"
  elif [ "$status" = "403" ] || [ "$status" = "404" ] || [[ "$status" == *"Access Denied"* ]] || [[ "$status" == *"reachable"* ]] || [[ "$status" == *"no mTLS"* ]]; then
    printf "${orange}%-10s  %-65s  %s${reset}\n" "$env" "$endpoint" "$status"
  else
    printf "${red}%-10s  %-65s  %s${reset}\n" "$env" "$endpoint" "$status"
  fi
done
echo "--------------------------------------------------------------------------------------------------------------"

# Summary
if [ "$has_warnings" = true ]; then
  echo -e "\n${orange}Services with warnings:${reset}"
  for i in "${!warning_endpoints[@]}"; do
    printf "${orange}  - %-63s: %s${reset}\n" "${warning_endpoints[$i]}" "${warning_statuses[$i]}"
  done
  echo -e "${orange}Note: 404 = ingress reached but no route matched. 403/AccessDenied on AWS = reachable.${reset}"
fi

if [ "$has_failures" = true ]; then
  echo -e "\n${red}Services that failed connectivity check:${reset}"
  for i in "${!failed_endpoints[@]}"; do
    printf "${red}  - %-63s: %s${reset}\n" "${failed_endpoints[$i]}" "${failed_statuses[$i]}"
  done
  echo -e "\n${red}Action required: Please check firewall rules and network connectivity for failed services.${reset}"
  exit 1
fi

if [ "$has_failures" = false ] && [ "$has_warnings" = false ]; then
  echo -e "\n${green}All services reachable - connectivity check passed!${reset}"
  exit 0
elif [ "$has_failures" = false ]; then
  echo -e "\n${green}All services reachable (some with expected warnings)${reset}"
  exit 0
fi
