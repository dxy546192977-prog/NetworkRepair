#!/usr/bin/env bash
# ============================================================================
#  network_repair.sh — Cursor Network Repair Assistant (macOS)
#  Core repair logic; invoked via bin/cursor-network-repair
# ============================================================================

set -euo pipefail

# ── Resolve APP_ROOT ────────────────────────────────────────────────────────
if [[ -z "${APP_ROOT:-}" ]]; then
    APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

# ── Source the check library ────────────────────────────────────────────────
source "$APP_ROOT/lib/network_check.sh"

# ── Load settings (overrides defaults from settings.json if present) ───────
load_settings

# ── Version ─────────────────────────────────────────────────────────────────
VERSION="unknown"
if [[ -f "$APP_ROOT/VERSION" ]]; then
    VERSION="$(tr -d '\n' < "$APP_ROOT/VERSION")"
fi

# ── Colour helpers (disabled when stdout is not a terminal) ─────────────────
if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_RED="\033[0;31m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[0;33m"
    C_WHITE="\033[1;37m"
    C_GRAY="\033[0;37m"
    C_DARK="\033[0;90m"
else
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_WHITE="" C_GRAY="" C_DARK=""
fi

# ── Globals ─────────────────────────────────────────────────────────────────
LOG_DIR="$APP_ROOT/logs"
NO_DNS_CHANGE=false
FORCE_REPAIR=false
STARTED_AT=$(date +%s)

# ── Argument parsing ───────────────────────────────────────────────────────
usage() {
    echo "Cursor Network Repair Assistant v${VERSION} (macOS)"
    echo ""
    echo "Usage: cursor-network-repair [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --no-dns-change   Skip DNS server changes, only flush cache / reset proxy"
    echo "  --force-repair    Run repair even if all pre-checks pass"
    echo "  --help            Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-dns-change) NO_DNS_CHANGE=true; shift ;;
        --force-repair)  FORCE_REPAIR=true;  shift ;;
        --help|-h)       usage ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# ── OS guard ────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This script is designed for macOS. Detected: $(uname -s)"
    exit 1
fi

# ── Logging setup ───────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
TIME_TAG=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/network-repair-mac-$TIME_TAG.log"

# Duplicate all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

# ── Output helpers ──────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${C_DARK}########################################################################${C_RESET}"
    echo -e "${C_WHITE}#            Cursor Network Repair Assistant  (macOS)                 #${C_RESET}"
    echo -e "${C_DARK}########################################################################${C_RESET}"
    echo -e "${C_GRAY}  v${VERSION} — Checks DNS, TCP 443, HTTPS policy hints, and repairs network.${C_RESET}"
}

print_section() {
    local title="$1"
    echo ""
    echo -e "${C_DARK}========================================================================${C_RESET}"
    echo -e "${C_WHITE}${title}${C_RESET}"
    echo -e "${C_DARK}========================================================================${C_RESET}"
}

print_info() {
    local label="$1"
    local value="$2"
    printf "  ${C_GRAY}%-20s : %s${C_RESET}\n" "$label" "$value"
}

print_step() {
    local num="$1"
    local total="$2"
    local title="$3"
    echo ""
    echo -e "${C_WHITE}[${num}/${total}] ${title}${C_RESET}"
}

# ── Print endpoint table ───────────────────────────────────────────────────
print_endpoint_table() {
    local title="$1"
    print_section "$title"

    local i=0
    local count=${#RESULT_HOSTS[@]}
    while [[ $i -lt $count ]]; do
        local host="${RESULT_HOSTS[$i]}"
        local dns="${RESULT_DNS[$i]}"
        local tcp="${RESULT_TCP[$i]}"
        local passed="${RESULT_PASS[$i]}"

        local status dns_label tcp_label color

        if [[ "$passed" == "true" ]]; then
            status="[PASS]"
            color="$C_GREEN"
        else
            status="[FAIL]"
            color="$C_RED"
        fi

        if [[ "$dns" == "true" ]]; then
            dns_label="DNS OK "
        else
            dns_label="DNS ERR"
        fi

        if [[ "$tcp" == "true" ]]; then
            tcp_label="TCP OK "
        else
            tcp_label="TCP ERR"
        fi

        printf "  ${color}%s  %-24s  %s  %s${C_RESET}\n" "$status" "$host" "$dns_label" "$tcp_label"
        i=$((i + 1))
    done
}

# ── Print HTTPS probe card ─────────────────────────────────────────────────
print_https_probe() {
    local title="$1"
    print_section "$title"
    print_info "URL" "$PROBE_URI"

    if [[ "$PROBE_REACHABLE" == "true" ]]; then
        print_info "TLS / HTTP" "Response received"
    else
        print_info "TLS / HTTP" "No HTTP response"
    fi

    print_info "HTTP status" "${PROBE_HTTP_STATUS:-N/A}"

    if [[ "$PROBE_REGION_BLOCK" == "true" ]]; then
        print_info "Region hint" "Likely policy / region related"
    else
        print_info "Region hint" "No obvious region hint"
    fi

    if [[ -n "$PROBE_ERROR" ]]; then
        print_info "Error detail" "$PROBE_ERROR"
    fi
}

print_https_interpretation() {
    local api2_passed="$1"

    echo ""
    if [[ "$PROBE_REACHABLE" != "true" ]]; then
        echo -e "${C_YELLOW}HTTPS probe: TLS/HTTP failed before a response. Treat as connectivity/TLS/proxy issue.${C_RESET}"
        if [[ -n "$PROBE_ERROR" ]]; then
            echo -e "  ${C_DARK}Detail: ${PROBE_ERROR}${C_RESET}"
        fi
        return
    fi

    if [[ "$PROBE_REGION_BLOCK" == "true" ]]; then
        echo -e "${C_YELLOW}HTTPS probe: got HTTP response (TLS OK). Status: ${PROBE_HTTP_STATUS}${C_RESET}"
    else
        echo -e "${C_GREEN}HTTPS probe: got HTTP response (TLS OK). Status: ${PROBE_HTTP_STATUS}${C_RESET}"
    fi

    if [[ "$api2_passed" == "true" && "$PROBE_REGION_BLOCK" == "true" ]]; then
        echo ""
        echo -e "${C_YELLOW}TCP to api2.cursor.sh is OK but HTTP suggests policy/region.${C_RESET}"
        echo -e "${C_YELLOW}Local DNS/stack repair may NOT fix Cursor 'Model not available / region'.${C_RESET}"
        echo -e "${C_WHITE}See: https://cursor.com/docs/account/regions${C_RESET}"
        echo -e "${C_DARK}Check Cursor account, billing region, and provider availability.${C_RESET}"
    elif [[ "$api2_passed" == "true" && "$PROBE_REGION_BLOCK" != "true" ]]; then
        echo -e "${C_DARK}No obvious region signal. If Cursor still shows region errors, read the regions doc.${C_RESET}"
    fi
}

# ── Repair steps ───────────────────────────────────────────────────────────
run_repair() {
    local change_dns="$1"
    local total_steps=7

    print_section "Running repair steps (macOS)"

    # Step 0 (internal): Detect and clean hosts file hijacking
    print_step 1 $total_steps "Check /etc/hosts for hijacked domains"
    local hosts_cleaned=false
    local hosts_backup="/tmp/hosts_backup_$(date +%Y%m%d%H%M%S)"
    for target in "${TARGETS[@]}"; do
        if grep -qiE "^[^#]*[[:space:]]${target}" /etc/hosts 2>/dev/null; then
            if [[ "$hosts_cleaned" == "false" ]]; then
                echo -e "  ${C_YELLOW}[WARN] Found hijacked entries in /etc/hosts:${C_RESET}"
                sudo cp /etc/hosts "$hosts_backup"
                echo -e "  ${C_DARK}Backup saved to: ${hosts_backup}${C_RESET}"
                hosts_cleaned=true
            fi
            local matched_line
            matched_line=$(grep -iE "^[^#]*[[:space:]]${target}" /etc/hosts)
            echo -e "    ${C_RED}${matched_line}${C_RESET}"
            sudo sed -i '' "/^[^#]*[[:space:]]${target}/d" /etc/hosts 2>/dev/null || true
        fi
    done
    if [[ "$hosts_cleaned" == "true" ]]; then
        echo -e "  ${C_GREEN}[OK] Hijacked entries removed from /etc/hosts${C_RESET}"
    else
        echo -e "  ${C_GREEN}[OK] No hijacked entries found in /etc/hosts${C_RESET}"
    fi

    # Step 2: Flush DNS cache
    print_step 2 $total_steps "Flush DNS cache"
    echo "  Running: sudo dscacheutil -flushcache"
    sudo dscacheutil -flushcache 2>&1 || true
    echo "  Running: sudo killall -HUP mDNSResponder"
    sudo killall -HUP mDNSResponder 2>&1 || true
    echo -e "  ${C_GREEN}[OK] DNS cache flushed${C_RESET}"

    # Step 3: Restart mDNSResponder service
    print_step 3 $total_steps "Restart mDNSResponder service"
    if sudo launchctl kickstart -kp system/com.apple.mDNSResponder 2>&1; then
        echo -e "  ${C_GREEN}[OK] mDNSResponder restarted${C_RESET}"
    else
        echo -e "  ${C_YELLOW}[SKIP] launchctl kickstart not available or failed (non-critical)${C_RESET}"
    fi

    # Step 4: Clear ARP cache
    print_step 4 $total_steps "Clear ARP cache"
    if sudo arp -a -d 2>&1; then
        echo -e "  ${C_GREEN}[OK] ARP cache cleared${C_RESET}"
    else
        echo -e "  ${C_YELLOW}[SKIP] ARP cache clear failed (non-critical)${C_RESET}"
    fi

    # Step 5: Detect proxy settings
    print_step 5 $total_steps "Check proxy settings on active interfaces"
    local found_proxy=false
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        echo -e "  ${C_GRAY}Checking: ${svc}${C_RESET}"

        local web_proxy secure_proxy socks_proxy
        web_proxy=$(networksetup -getwebproxy "$svc" 2>/dev/null || true)
        secure_proxy=$(networksetup -getsecurewebproxy "$svc" 2>/dev/null || true)
        socks_proxy=$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null || true)

        if echo "$web_proxy" | grep -qi "^Enabled: Yes"; then
            echo -e "    ${C_YELLOW}[WARN] HTTP proxy is ENABLED${C_RESET}"
            echo "$web_proxy" | head -3 | sed 's/^/    /'
            found_proxy=true
        fi
        if echo "$secure_proxy" | grep -qi "^Enabled: Yes"; then
            echo -e "    ${C_YELLOW}[WARN] HTTPS proxy is ENABLED${C_RESET}"
            echo "$secure_proxy" | head -3 | sed 's/^/    /'
            found_proxy=true
        fi
        if echo "$socks_proxy" | grep -qi "^Enabled: Yes"; then
            echo -e "    ${C_YELLOW}[WARN] SOCKS proxy is ENABLED${C_RESET}"
            echo "$socks_proxy" | head -3 | sed 's/^/    /'
            found_proxy=true
        fi
    done < <(get_active_network_services)

    if [[ "$found_proxy" == "true" ]]; then
        echo -e "  ${C_YELLOW}Proxy detected. If Cursor cannot connect, consider disabling or configuring it.${C_RESET}"
    else
        echo -e "  ${C_GREEN}[OK] No proxy enabled on active interfaces${C_RESET}"
    fi

    # Step 6: Switch DNS to public resolvers
    print_step 6 $total_steps "Switch DNS to public resolvers (${DNS_PRIMARY} / ${DNS_SECONDARY})"
    if [[ "$change_dns" == "true" ]]; then
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            if sudo networksetup -setdnsservers "$svc" "$DNS_PRIMARY" "$DNS_SECONDARY" 2>&1; then
                echo -e "  ${C_GREEN}[OK] ${svc}${C_RESET}"
            else
                echo -e "  ${C_RED}[FAILED] ${svc}${C_RESET}"
            fi
        done < <(get_active_network_services)
        sudo dscacheutil -flushcache 2>/dev/null || true
        sudo killall -HUP mDNSResponder 2>/dev/null || true
    else
        echo -e "  ${C_DARK}DNS change skipped because --no-dns-change was used${C_RESET}"
    fi

    # Step 7: Fix Cursor proxy configuration
    print_step 7 $total_steps "Fix Cursor proxy settings (http.proxySupport → override)"
    local cursor_settings="$HOME/Library/Application Support/Cursor/User/settings.json"
    if [[ -f "$cursor_settings" ]]; then
        if grep -q '"http.proxySupport"' "$cursor_settings" 2>/dev/null; then
            local current_value
            current_value=$(grep '"http.proxySupport"' "$cursor_settings" | sed 's/.*: *"\([^"]*\)".*/\1/')
            if [[ "$current_value" != "override" ]]; then
                sed -i '' 's/"http.proxySupport": *"[^"]*"/"http.proxySupport": "override"/' "$cursor_settings" 2>/dev/null
                echo -e "  ${C_GREEN}[OK] Changed http.proxySupport: \"${current_value}\" → \"override\"${C_RESET}"
            else
                echo -e "  ${C_GREEN}[OK] http.proxySupport is already \"override\"${C_RESET}"
            fi
        else
            # Key doesn't exist, try to add it after the opening brace
            sed -i '' 's/^{$/{\n    "http.proxySupport": "override",/' "$cursor_settings" 2>/dev/null
            echo -e "  ${C_GREEN}[OK] Added http.proxySupport: \"override\" to Cursor settings${C_RESET}"
        fi

        # Also ensure http.proxyStrictSSL is false for proxy compatibility
        if grep -q '"http.proxyStrictSSL"' "$cursor_settings" 2>/dev/null; then
            local ssl_value
            ssl_value=$(grep '"http.proxyStrictSSL"' "$cursor_settings" | sed 's/.*: *\([a-z]*\).*/\1/')
            if [[ "$ssl_value" != "false" ]]; then
                sed -i '' 's/"http.proxyStrictSSL": *[a-z]*/"http.proxyStrictSSL": false/' "$cursor_settings" 2>/dev/null
                echo -e "  ${C_GREEN}[OK] Changed http.proxyStrictSSL: ${ssl_value} → false${C_RESET}"
            else
                echo -e "  ${C_GREEN}[OK] http.proxyStrictSSL is already false${C_RESET}"
            fi
        fi

        echo -e "  ${C_YELLOW}[NOTE] Restart Cursor for proxy changes to take effect${C_RESET}"
    else
        echo -e "  ${C_DARK}Cursor settings.json not found, skipping${C_RESET}"
    fi
}

# ── Final summary ──────────────────────────────────────────────────────────
print_summary() {
    local fail_count="$1"

    print_section "Summary"

    if [[ "$fail_count" -eq 0 ]]; then
        echo -e "  ${C_GREEN}[OK] DNS/TCP checks passed.${C_RESET}"
    else
        echo -e "  ${C_YELLOW}[WARN] ${fail_count} target(s) still have DNS/TCP problems.${C_RESET}"
    fi

    if [[ "$PROBE_REGION_BLOCK" == "true" ]]; then
        echo -e "  ${C_YELLOW}[INFO] HTTPS looks more like a provider policy / region limitation.${C_RESET}"
        echo -e "  ${C_WHITE}       https://cursor.com/docs/account/regions${C_RESET}"
    elif [[ "$PROBE_REACHABLE" != "true" ]]; then
        echo -e "  ${C_YELLOW}[INFO] HTTPS failed before policy evaluation. Focus on proxy/TLS/connectivity.${C_RESET}"
    fi
}

# ============================================================================
#  Main
# ============================================================================

print_banner

# ── Session info ────────────────────────────────────────────────────────────
print_section "Session"
print_info "Started" "$(date '+%Y-%m-%d %H:%M:%S')"
print_info "Version" "$VERSION"
print_info "OS" "$(sw_vers -productName 2>/dev/null || echo macOS) $(sw_vers -productVersion 2>/dev/null || echo '') ($(uname -m))"
print_info "Shell" "$BASH_VERSION"
print_info "App root" "$APP_ROOT"
print_info "Log file" "$LOG_FILE"
print_info "DNS change" "$(if $NO_DNS_CHANGE; then echo 'Disabled'; else echo 'Enabled'; fi)"
print_info "Force repair" "$(if $FORCE_REPAIR; then echo 'Enabled'; else echo 'Disabled'; fi)"

# ── Pre-check ───────────────────────────────────────────────────────────────
run_all_checks
print_endpoint_table "Pre-check"

api2_status=$(get_api2_status)
run_https_probe
print_https_probe "HTTPS probe (Cursor API)"
print_https_interpretation "$api2_status"

before_fail_count=$(count_failures)

if [[ "$before_fail_count" -eq 0 && "$FORCE_REPAIR" != true ]]; then
    echo ""
    echo -e "${C_GREEN}All TCP/DNS checks passed. No stack repair needed.${C_RESET}"
    echo -e "${C_DARK}Use --force-repair if you still want to run repair.${C_RESET}"
    echo -e "${C_DARK}If Cursor still shows 'region' errors, that is account/provider policy, not local TCP.${C_RESET}"
    print_summary "$before_fail_count"
else
    if [[ "$before_fail_count" -eq 0 ]]; then
        echo -e "${C_YELLOW}--force-repair enabled. Running repair...${C_RESET}"
    else
        echo -e "${C_YELLOW}${before_fail_count} target(s) failed. Running repair...${C_RESET}"
    fi

    dns_change_flag="$(if $NO_DNS_CHANGE; then echo 'false'; else echo 'true'; fi)"

    run_repair "$dns_change_flag"

    echo ""
    echo -e "${C_GRAY}Waiting 3 seconds for changes to take effect...${C_RESET}"
    sleep 3

    # ── Post-check ──────────────────────────────────────────────────────────
    run_all_checks
    print_endpoint_table "Post-check"

    api2_status=$(get_api2_status)
    run_https_probe
    print_https_probe "HTTPS probe (Cursor API) after repair"
    print_https_interpretation "$api2_status"

    after_fail_count=$(count_failures)

    # ── Auto-retry if still failing (up to 2 extra attempts) ────────────────
    max_retries=2
    retry=0
    wait_seconds=5

    while [[ "$after_fail_count" -gt 0 && "$retry" -lt "$max_retries" ]]; do
        retry=$((retry + 1))
        echo ""
        echo -e "${C_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo -e "${C_YELLOW}  Retry ${retry}/${max_retries}: ${after_fail_count} target(s) still failing.${C_RESET}"
        echo -e "${C_YELLOW}  Waiting ${wait_seconds}s before re-checking (DNS propagation may need time)...${C_RESET}"
        echo -e "${C_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        sleep "$wait_seconds"

        # Flush DNS again before retry
        echo -e "  ${C_GRAY}Flushing DNS cache again...${C_RESET}"
        sudo dscacheutil -flushcache 2>/dev/null || true
        sudo killall -HUP mDNSResponder 2>/dev/null || true
        sleep 2

        run_all_checks
        print_endpoint_table "Retry ${retry}/${max_retries}"

        after_fail_count=$(count_failures)
        wait_seconds=$((wait_seconds + 5))
    done

    # ── Final result ────────────────────────────────────────────────────────
    echo ""
    if [[ "$after_fail_count" -eq 0 ]]; then
        echo -e "${C_GREEN}╔══════════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_GREEN}║  ✅  Repair successful! All targets passed.                     ║${C_RESET}"
        echo -e "${C_GREEN}╚══════════════════════════════════════════════════════════════════╝${C_RESET}"
    else
        echo -e "${C_RED}╔══════════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_RED}║  ❌  ${after_fail_count} target(s) still failing after repair + ${max_retries} retries.       ║${C_RESET}"
        echo -e "${C_RED}╚══════════════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""
        echo -e "${C_WHITE}Recommended next steps:${C_RESET}"
        echo ""
        echo -e "  ${C_YELLOW}1.${C_RESET} ${C_WHITE}Check proxy / VPN software${C_RESET}"
        echo -e "     ${C_GRAY}Quit ClashX, Surge, V2Ray, Shadowrocket, or similar tools,${C_RESET}"
        echo -e "     ${C_GRAY}then re-run this script.${C_RESET}"
        echo ""
        echo -e "  ${C_YELLOW}2.${C_RESET} ${C_WHITE}Try a different network${C_RESET}"
        echo -e "     ${C_GRAY}Switch from corporate Wi-Fi to mobile hotspot or home network.${C_RESET}"
        echo ""
        echo -e "  ${C_YELLOW}3.${C_RESET} ${C_WHITE}Try alternative DNS servers${C_RESET}"
        echo -e "     ${C_GRAY}System Preferences → Network → DNS → try 223.5.5.5 (Alibaba)${C_RESET}"
        echo -e "     ${C_GRAY}or 114.114.114.114, then re-run this script.${C_RESET}"
        echo ""
        echo -e "  ${C_YELLOW}4.${C_RESET} ${C_WHITE}Check /etc/hosts manually${C_RESET}"
        echo -e "     ${C_GRAY}Run: sudo nano /etc/hosts${C_RESET}"
        echo -e "     ${C_GRAY}Remove any lines pointing cursor/openai/anthropic domains to 127.0.0.1${C_RESET}"
        echo ""
        echo -e "  ${C_YELLOW}5.${C_RESET} ${C_WHITE}Re-run this script after making changes${C_RESET}"
        echo -e "     ${C_GRAY}Each run will re-check all endpoints and attempt repair again.${C_RESET}"
        echo ""
        echo -e "${C_DARK}Log saved to: ${LOG_FILE}${C_RESET}"
    fi

    # Update HTTPS probe for final summary
    api2_status=$(get_api2_status)
    run_https_probe
    print_summary "$after_fail_count"
fi

# ── Elapsed time ────────────────────────────────────────────────────────────
ENDED_AT=$(date +%s)
ELAPSED=$((ENDED_AT - STARTED_AT))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))
echo ""
echo -e "${C_WHITE}Completed in $(printf '%02d:%02d' $ELAPSED_MIN $ELAPSED_SEC)${C_RESET}"
echo ""
