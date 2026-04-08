#!/usr/bin/env bash
# ============================================================================
#  network_check.sh — Network detection function library
#  Sourced by network_repair.sh; do not execute directly.
# ============================================================================

# ── Defaults (overridden by settings.json if present) ─────────────────────
TARGETS=(
    "api.openai.com"
    "chat.openai.com"
    "api.anthropic.com"
    "claude.ai"
    "api2.cursor.sh"
    "api.cursor.sh"
)
TIMEOUT_DNS=4
TIMEOUT_TCP=6
TIMEOUT_HTTPS_PROBE=20
DNS_PRIMARY="1.1.1.1"
DNS_SECONDARY="8.8.8.8"
DEFAULT_PROBE_URL="https://api2.cursor.sh/"

# ── Load settings from JSON (if available) ────────────────────────────────
load_settings() {
    local settings_file="${APP_ROOT:-}/support/settings.json"
    [[ -f "$settings_file" ]] || return 0

    local json
    json=$(<"$settings_file") || return 0

    local parsed
    parsed=$(python3 -c "
import json, sys
try:
    s = json.loads(sys.stdin.read())
    t = s.get('targets', [])
    if t:
        print('TARGETS=(' + ' '.join('\"' + h + '\"' for h in t) + ')')
    d = s.get('dns', {})
    if d.get('primary'):
        print('DNS_PRIMARY=\"' + d['primary'] + '\"')
    if d.get('secondary'):
        print('DNS_SECONDARY=\"' + d['secondary'] + '\"')
    to = s.get('timeouts', {})
    if to.get('dns_sec'):
        print('TIMEOUT_DNS=' + str(int(to['dns_sec'])))
    if to.get('tcp_sec'):
        print('TIMEOUT_TCP=' + str(int(to['tcp_sec'])))
    if to.get('https_probe_sec'):
        print('TIMEOUT_HTTPS_PROBE=' + str(int(to['https_probe_sec'])))
    p = s.get('probe_url')
    if p:
        print('DEFAULT_PROBE_URL=\"' + p + '\"')
except Exception:
    pass
" <<< "$json" 2>/dev/null) || return 0

    eval "$parsed" 2>/dev/null || true
}

# ── Result arrays ───────────────────────────────────────────────────────────
declare -a RESULT_HOSTS=()
declare -a RESULT_DNS=()
declare -a RESULT_TCP=()
declare -a RESULT_PASS=()

# ── HTTPS probe state ──────────────────────────────────────────────────────
PROBE_URI=""
PROBE_REACHABLE="false"
PROBE_HTTP_STATUS=""
PROBE_BODY=""
PROBE_ERROR=""
PROBE_REGION_BLOCK="false"

# ── Run command with hard timeout (kills process if stuck) ──────────────────
run_with_timeout() {
    local timeout_sec="$1"
    shift
    "$@" &
    local pid=$!
    (
        sleep "$timeout_sec"
        kill "$pid" 2>/dev/null
    ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local exit_code=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return $exit_code
}

# ── DNS resolution test ────────────────────────────────────────────────────
test_dns() {
    local host="$1"
    local t=$((TIMEOUT_DNS))
    local ct=$((t > 1 ? t - 1 : 1))
    if run_with_timeout "$t" curl -s --connect-timeout "$ct" --max-time "$ct" -o /dev/null "https://$host/" 2>/dev/null; then
        return 0
    fi
    local result
    result=$(run_with_timeout "$t" dig +short +time=2 +tries=1 "$host" 2>/dev/null) || true
    if echo "$result" | grep -qE '^[0-9]+\.|^[0-9a-f:]+'; then
        return 0
    fi
    return 1
}

# ── TCP 443 connectivity test ──────────────────────────────────────────────
test_tcp443() {
    local host="$1"
    local t=$((TIMEOUT_TCP))
    local ct=$((t > 1 ? t - 1 : 1))
    if run_with_timeout "$t" curl -s --connect-timeout "$ct" --max-time "$((t - 1))" -o /dev/null -w '' "https://$host/" 2>/dev/null; then
        return 0
    fi
    if run_with_timeout "$t" nc -z -w "$ct" "$host" 443 2>/dev/null; then
        return 0
    fi
    return 1
}

# ── Test a single endpoint (DNS + TCP) ─────────────────────────────────────
test_endpoint() {
    local host="$1"
    local dns_ok="false"
    local tcp_ok="false"

    if test_dns "$host"; then
        dns_ok="true"
    fi

    if test_tcp443 "$host"; then
        tcp_ok="true"
    fi

    local passed="false"
    if [[ "$dns_ok" == "true" && "$tcp_ok" == "true" ]]; then
        passed="true"
    fi

    RESULT_HOSTS+=("$host")
    RESULT_DNS+=("$dns_ok")
    RESULT_TCP+=("$tcp_ok")
    RESULT_PASS+=("$passed")
}

# ── Run all endpoint checks ────────────────────────────────────────────────
run_all_checks() {
    RESULT_HOSTS=()
    RESULT_DNS=()
    RESULT_TCP=()
    RESULT_PASS=()

    local total=${#TARGETS[@]}
    local idx=0
    for target in "${TARGETS[@]}"; do
        idx=$((idx + 1))
        printf "  Checking [%d/%d] %s ..." "$idx" "$total" "$target"
        test_endpoint "$target"
        # Print inline result
        local last=$((${#RESULT_PASS[@]} - 1))
        if [[ "${RESULT_PASS[$last]}" == "true" ]]; then
            printf " OK\n"
        else
            printf " FAIL\n"
        fi
    done
}

# ── Count failures ─────────────────────────────────────────────────────────
count_failures() {
    local fails=0
    local i=0
    local count=${#RESULT_PASS[@]}
    while [[ $i -lt $count ]]; do
        if [[ "${RESULT_PASS[$i]}" != "true" ]]; then
            fails=$((fails + 1))
        fi
        i=$((i + 1))
    done
    echo "$fails"
}

# ── Get api2.cursor.sh pass status ─────────────────────────────────────────
get_api2_status() {
    local i=0
    local count=${#RESULT_HOSTS[@]}
    while [[ $i -lt $count ]]; do
        if [[ "${RESULT_HOSTS[$i]}" == "api2.cursor.sh" ]]; then
            echo "${RESULT_PASS[$i]}"
            return
        fi
        i=$((i + 1))
    done
    echo "false"
}

# ── HTTPS probe (Cursor API) ──────────────────────────────────────────────
run_https_probe() {
    local uri="${1:-$DEFAULT_PROBE_URL}"
    PROBE_URI="$uri"
    PROBE_REACHABLE="false"
    PROBE_HTTP_STATUS=""
    PROBE_BODY=""
    PROBE_ERROR=""
    PROBE_REGION_BLOCK="false"

    local tmp_body
    tmp_body=$(mktemp /tmp/cursor_probe_XXXXXX)
    local tmp_headers
    tmp_headers=$(mktemp /tmp/cursor_headers_XXXXXX)

    local http_code
    local probe_timeout=$((TIMEOUT_HTTPS_PROBE))
    local probe_ct=$((probe_timeout / 2))
    http_code=$(curl -s -o "$tmp_body" -D "$tmp_headers" -w "%{http_code}" \
        --connect-timeout "$probe_ct" --max-time "$probe_timeout" \
        -L "$uri" 2>/dev/null) || true

    if [[ -n "$http_code" && "$http_code" != "000" ]]; then
        PROBE_REACHABLE="true"
        PROBE_HTTP_STATUS="$http_code"
        PROBE_BODY=$(head -c 2000 "$tmp_body" 2>/dev/null || true)
    else
        PROBE_ERROR="Connection failed or timed out (curl exit or HTTP 000)"
    fi

    # Check for region/policy signals
    local haystack
    haystack=$(echo "${PROBE_BODY} ${PROBE_ERROR}" | tr '[:upper:]' '[:lower:]')

    if [[ "$PROBE_HTTP_STATUS" == "403" || "$PROBE_HTTP_STATUS" == "451" ]]; then
        PROBE_REGION_BLOCK="true"
    fi

    if echo "$haystack" | grep -qE 'region|does not serve|not available|unsupported country|unavailable in your|doesn.t serve'; then
        PROBE_REGION_BLOCK="true"
    fi

    rm -f "$tmp_body" "$tmp_headers"
}

# ── Get active network service names ───────────────────────────────────────
get_active_network_services() {
    local services=()
    while IFS= read -r svc; do
        [[ -z "$svc" || "$svc" == *"denotes"* ]] && continue
        svc=$(echo "$svc" | sed 's/^[* ]*//')
        [[ -z "$svc" ]] && continue
        local ip
        ip=$(networksetup -getinfo "$svc" 2>/dev/null | grep "^IP address:" | awk '{print $3}') || true
        if [[ -n "$ip" && "$ip" != "none" ]]; then
            services+=("$svc")
        fi
    done < <(networksetup -listallnetworkservices 2>/dev/null)
    printf '%s\n' "${services[@]}"
}
