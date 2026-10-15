#!/bin/bash
# run this script from any node / machine inside the network you will be using
# to deploy the Akeyless gateway

set -uo pipefail

# Configuration
# Set TENANT_PREFIX to target a single-tenant domain (e.g. "mytenant" → console.mytenant.akeyless.io)
# Leave empty for multi-tenant (e.g. console.akeyless.io)
TENANT_PREFIX=${TENANT_PREFIX:-""}
AKEYLESS_DOMAIN=${AKEYLESS_DOMAIN:-"akeyless.io"}
CONNECT_TIMEOUT=5
MAX_TIME=10

# Build the domain suffix: ".mytenant.akeyless.io" or ".akeyless.io"
if [ -n "$TENANT_PREFIX" ]; then
  AKEYLESS_SUFFIX=".$TENANT_PREFIX.$AKEYLESS_DOMAIN"
else
  AKEYLESS_SUFFIX=".$AKEYLESS_DOMAIN"
fi

# Akeyless services with /status
akeyless_services=(
  console vault vault-ro auth auth-ro audit audit-ro
  bis bis-ro gator gator-ro kfm1 kfm1-ro kfm2 kfm2-ro kfm3 kfm3-ro
  kfm4 kfm4-ro rest
)

# Services without /status
other_services=(
  auth-cert
  hvp
  akeyless-cli.s3.us-east-2.amazonaws.com
  akeylessservices.s3.us-east-2.amazonaws.com
  sqs.us-east-2.amazonaws.com
  mq
  log-9997
  log-9443
)

# Color codes
green="\033[1;32m"
orange="\033[1;33m"
red="\033[1;31m"
reset="\033[0m"

# Arrays to store results
endpoints=()
statuses=()
dns_ips=()
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

# Helper function to resolve hostname to IPs
resolve_host() {
  local host="$1"
  # Try dig first, fall back to host, then getent
  if command -v dig &>/dev/null; then
    dig +short "$host" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ',' | sed 's/,$//'
  elif command -v host &>/dev/null; then
    host "$host" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ',' | sed 's/,$//'
  elif command -v getent &>/dev/null; then
    getent hosts "$host" 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//'
  else
    echo "n/a"
  fi
}

# Collect results for akeyless_services
for s in "${akeyless_services[@]}"; do
  hostname="$s$AKEYLESS_SUFFIX"
  endpoint="$hostname/status"
  endpoints+=("$endpoint")
  resolved=$(resolve_host "$hostname")
  dns_ips+=("${resolved:-unresolved}")
  status=$(curl_with_timeout -sIL -o /dev/null -w "%{http_code}" "https://$endpoint" 2>/dev/null)
  status=${status:-000}
  statuses+=("$status")
  if [ "$status" = "200" ]; then
    :
  elif [ "$status" = "403" ]; then
    # 403 = ingress reached but auth required (e.g. console). Reachable.
    has_warnings=true
    warning_endpoints+=("$endpoint")
    warning_statuses+=("$status (reachable)")
  else
    has_failures=true
    failed_endpoints+=("$endpoint")
    failed_statuses+=("$status")
  fi
done

# Collect results for other_services
for s in "${other_services[@]}"; do
  endpoint="$s"
  
  if [ "$s" = "auth-cert" ]; then
    endpoint="$s$AKEYLESS_SUFFIX"
    endpoints+=("$endpoint")
    resolved=$(resolve_host "$endpoint")
    dns_ips+=("${resolved:-unresolved}")
    # Check for successful SSL/TLS handshake with certificate exchange
    curl_output=$(curl_with_timeout -v -s -o /dev/null "https://$endpoint" 2>&1 || true)
    if echo "$curl_output" | grep -qE "(SSL certificate|server certificate|TLS handshake)"; then
      statuses+=("mTLS Handshake")
    else
      statuses+=("No Response")
      has_failures=true
      failed_endpoints+=("$endpoint")
      failed_statuses+=("No Response")
    fi
    
  elif [ "$s" = "hvp" ]; then
    hostname="$s$AKEYLESS_SUFFIX"
    endpoint="$hostname/v1/sys/health"
    endpoints+=("$endpoint")
    resolved=$(resolve_host "$hostname")
    dns_ips+=("${resolved:-unresolved}")
    response=$(curl_with_timeout -s "https://$endpoint" 2>/dev/null || true)
    if echo "$response" | grep -q '"version":"akeyless-hvp'; then
      statuses+=("akeyless-hvp")
    else
      status=$(curl_with_timeout -sIL -o /dev/null -w "%{http_code}" "https://$endpoint" 2>/dev/null)
      status=${status:-000}
      statuses+=("$status")
      has_failures=true
      failed_endpoints+=("$endpoint")
      failed_statuses+=("$status")
    fi
    
  elif [ "$s" = "sqs.us-east-2.amazonaws.com" ]; then
    endpoints+=("$endpoint")
    resolved=$(resolve_host "$s")
    dns_ips+=("${resolved:-unresolved}")
    response=$(curl_with_timeout -s -X POST "https://$s" -d "Action=ListQueues&Version=2012-11-05" 2>/dev/null || true)
    if echo "$response" | grep -q '<Code>AccessDenied</Code>'; then
      # Access Denied means we reached AWS - this is expected without auth
      statuses+=("Access Denied (reachable)")
      has_warnings=true
      warning_endpoints+=("$endpoint")
      warning_statuses+=("Access Denied (reachable)")
    elif echo "$response" | grep -qE '<ListQueuesResponse|<ListQueuesResult>'; then
      # Unexpected success - but still reachable
      statuses+=("200")
    else
      status=$(curl_with_timeout -sIL -o /dev/null -w "%{http_code}" "https://$s" 2>/dev/null)
      status=${status:-000}
      statuses+=("Error ($status)")
      has_failures=true
      failed_endpoints+=("$endpoint")
      failed_statuses+=("Error ($status)")
    fi
    
  elif [ "$s" = "mq" ]; then
    # RabbitMQ AMQPS check on port 5671
    hostname="$s$AKEYLESS_SUFFIX"
    endpoint="$hostname:5671"
    endpoints+=("$endpoint")
    resolved=$(resolve_host "$hostname")
    dns_ips+=("${resolved:-unresolved}")
    # Use --http0.9 to handle non-HTTP protocol response from AMQP
    curl_output=$(curl -v --http0.9 --connect-timeout 3 --max-time 3 "https://$endpoint" 2>&1 || true)
    connected_line=$(echo "$curl_output" | grep -oE "Connected to [^ ]+ \([0-9.]+\) port [0-9]+" || true)
    if [ -n "$connected_line" ]; then
      # Extract IP and port from: "Connected to mq.akeyless.io (52.223.11.194) port 5671"
      ip_addr=$(echo "$connected_line" | grep -oE '\([0-9.]+\)' | tr -d '()')
      port=$(echo "$connected_line" | grep -oE 'port [0-9]+' | awk '{print $2}')
      statuses+=("AMQPS Connected ($ip_addr:$port)")
    else
      statuses+=("AMQPS Connection Failed")
      has_failures=true
      failed_endpoints+=("$endpoint")
      failed_statuses+=("AMQPS Connection Failed on port 5671")
    fi
    
  elif [[ "$s" == "log-9997" ]] || [[ "$s" == "log-9443" ]]; then
    # Log service TCP check
    port="${s##*-}"  # Extract port from service name (9997 or 9443)
    hostname="log$AKEYLESS_SUFFIX"
    endpoint="$hostname:$port"
    endpoints+=("$endpoint")
    resolved=$(resolve_host "$hostname")
    dns_ips+=("${resolved:-unresolved}")
    # Use --http0.9 to handle non-HTTP protocol response
    curl_output=$(curl -v --http0.9 --connect-timeout 3 --max-time 3 "https://$endpoint" 2>&1 || true)
    connected_line=$(echo "$curl_output" | grep -oE "Connected to [^ ]+ \([0-9.]+\) port [0-9]+" || true)
    if [ -n "$connected_line" ]; then
      # Extract IP and port from: "Connected to log.akeyless.io (x.x.x.x) port 9997"
      ip_addr=$(echo "$connected_line" | grep -oE '\([0-9.]+\)' | tr -d '()')
      conn_port=$(echo "$connected_line" | grep -oE 'port [0-9]+' | awk '{print $2}')
      statuses+=("TCP Connected ($ip_addr:$conn_port)")
    else
      statuses+=("TCP Connection Failed")
      has_failures=true
      failed_endpoints+=("$endpoint")
      failed_statuses+=("TCP Connection Failed on port $port")
    fi
    
  else
    # S3 buckets
    endpoints+=("$endpoint")
    resolved=$(resolve_host "$s")
    dns_ips+=("${resolved:-unresolved}")
    status=$(curl_with_timeout -sIL -o /dev/null -w "%{http_code}" "https://$s" 2>/dev/null)
    status=${status:-000}
    statuses+=("$status")
    if [ "$status" = "200" ]; then
      : # Success, nothing to do
    elif [ "$status" = "403" ]; then
      # 403 means we reached S3 but don't have permission - this is expected
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

# Print results
echo -e "\n${green}Connectivity Check Results:${reset}"
echo "--------------------------------------------------------------------------------------------"
printf "%-50s  %-30s  %s\n" "ENDPOINT" "DNS" "STATUS"
echo "--------------------------------------------------------------------------------------------"
for i in "${!endpoints[@]}"; do
  endpoint="${endpoints[$i]}"
  status="${statuses[$i]}"
  dns="${dns_ips[$i]}"
  if [ "$status" = "200" ] || [ "$status" = "mTLS Handshake" ] || [ "$status" = "akeyless-hvp" ] || [[ "$status" == "AMQPS Connected"* ]] || [[ "$status" == "TCP Connected"* ]]; then
    printf "${green}%-50s  %-30s  %s${reset}\n" "$endpoint" "$dns" "$status"
  elif [ "$status" = "403" ] || [[ "$status" == *"Access Denied"* ]] || [[ "$status" == *"reachable"* ]]; then
    printf "${orange}%-50s  %-30s  %s${reset}\n" "$endpoint" "$dns" "$status"
  else
    printf "${red}%-50s  %-30s  %s${reset}\n" "$endpoint" "$dns" "$status"
  fi
done
echo "--------------------------------------------------------------------------------------------"

# Summary
if [ "$has_warnings" = true ]; then
  echo -e "\n${orange}Services with warnings (reachable but require authentication):${reset}"
  for i in "${!warning_endpoints[@]}"; do
    printf "${orange}  - %-48s: %s${reset}\n" "${warning_endpoints[$i]}" "${warning_statuses[$i]}"
  done
  echo -e "${orange}Note: AWS services return 403/AccessDenied without credentials, but connectivity is confirmed.${reset}"
fi

if [ "$has_failures" = true ]; then
  echo -e "\n${red}Services that failed connectivity check:${reset}"
  for i in "${!failed_endpoints[@]}"; do
    printf "${red}  - %-48s: %s${reset}\n" "${failed_endpoints[$i]}" "${failed_statuses[$i]}"
  done
  echo -e "${red}Note: 000 = no HTTP response (DNS failure, TCP/TLS failure, or timeout — the request never got a status line back).${reset}"
  echo -e "\n${red}Action required: Please check firewall rules and network connectivity for failed services.${reset}"
  exit 1
fi

if [ "$has_failures" = false ] && [ "$has_warnings" = false ]; then
  echo -e "\n${green}✓ All services reachable - connectivity check passed!${reset}"
  exit 0
elif [ "$has_failures" = false ]; then
  echo -e "\n${green}✓ All services reachable (some with expected auth warnings)${reset}"
  exit 0
fi
