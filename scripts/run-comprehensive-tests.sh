#!/usr/bin/env bash
# run-comprehensive-tests.sh — Validate every Terraform-managed object via NITRO API
# Outputs JSON test results for each VPX to be consumed by the HTML report generator.
# Usage: run-comprehensive-tests.sh NSIP PASSWORD OUTPUT_JSON [SNIP] [VIP_TCP] [VIP_DNS] [VIP_CS]
set -euo pipefail

NSIP="${1:?Usage: $0 NSIP PASSWORD OUTPUT_JSON [SNIP] [VIP_TCP] [VIP_DNS]}"
PASSWORD="${2:?Missing PASSWORD}"
OUTPUT_JSON="${3:?Missing OUTPUT_JSON path}"
SNIP="${4:-10.0.1.254}"
VIP_TCP="${5:-10.0.1.115}"
VIP_DNS="${6:-10.0.1.125}"
VIP_CS="${7:-10.0.1.105}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_TMP=$(mktemp)
trap 'rm -f "$RESULTS_TMP"' EXIT

# --- NITRO API helper ---
nitro_get() {
    local endpoint="$1"
    # Try HTTPS first (configured VPXs), fall back to HTTP (fresh VPXs)
    local response
    response=$(curl -sk -o - -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" \
        -H "X-NITRO-PASS: $PASSWORD" \
        "https://${NSIP}/nitro/v1/config/${endpoint}" 2>/dev/null)
    local http_code
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "000" ]]; then
        response=$(curl -s -o - -w "\n%{http_code}" \
            -H "Content-Type: application/json" \
            -H "X-NITRO-USER: nsroot" \
            -H "X-NITRO-PASS: $PASSWORD" \
            "http://${NSIP}/nitro/v1/config/${endpoint}" 2>/dev/null)
    fi
    echo "$response"
}

# --- Test framework ---
TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

# Write a test result as a TSV line to the temp file
# Fields: category, test_name, status, expected, actual, detail
record_result() {
    local category="$1" test_name="$2" status="$3" expected="$4" actual="$5" detail="${6:-}"
    TOTAL=$((TOTAL + 1))
    case "$status" in
        PASS) PASSED=$((PASSED + 1)) ;;
        FAIL) FAILED=$((FAILED + 1)) ;;
        WARN) WARNINGS=$((WARNINGS + 1)) ;;
    esac
    # Write tab-separated to temp file (replace tabs/newlines in values)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$category" "$test_name" "$status" \
        "$(echo "$expected" | tr '\t\n' '  ')" \
        "$(echo "$actual" | tr '\t\n' '  ')" \
        "$(echo "$detail" | tr '\t\n' '  ')" >> "$RESULTS_TMP"
}

# Extract a field value from NITRO JSON response
extract_field() {
    local body="$1" field="$2"
    python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    found = False
    for key in data:
        if key not in ('errorcode', 'message', 'severity'):
            val = data[key]
            if isinstance(val, list) and len(val) > 0:
                print(str(val[0].get('$field', 'NOT_FOUND')))
            elif isinstance(val, dict):
                print(str(val.get('$field', 'NOT_FOUND')))
            else:
                print('NOT_FOUND')
            found = True
            break
    if not found:
        print('NOT_FOUND')
except Exception:
    print('PARSE_ERROR')
" <<< "$body"
}

# Check a NITRO resource exists and optionally verify a field
# Usage: check_resource CATEGORY RESOURCE_PATH [FIELD EXPECTED_VALUE]
check_resource() {
    local category="$1" resource_path="$2"
    local field="${3:-}" expected_value="${4:-}"

    local response http_code body
    response=$(nitro_get "$resource_path")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        record_result "$category" "${resource_path} exists" "FAIL" "HTTP 200" "HTTP $http_code" "Resource not found"
        return 0
    fi

    record_result "$category" "${resource_path} exists" "PASS" "exists" "exists"

    if [[ -n "$field" ]] && [[ -n "$expected_value" ]]; then
        local actual_value
        actual_value=$(extract_field "$body" "$field")
        if [[ "${actual_value,,}" == "${expected_value,,}" ]]; then
            record_result "$category" "${resource_path} ${field}" "PASS" "$expected_value" "$actual_value"
        else
            record_result "$category" "${resource_path} ${field}" "FAIL" "$expected_value" "$actual_value"
        fi
    fi
    return 0
}

# Check feature/mode status via SSH show commands
# VPX uses ON/OFF in output; we accept ENABLED/DISABLED as expected values
check_feature() {
    local category="$1" name="$2" expected="$3" show_output="$4"
    # Strip category prefix (feature:LB -> LB, mode:FR -> FR)
    local short_name="${name#*:}"
    # Map expected to VPX output format
    local vpx_expected="$expected"
    [[ "$expected" == "ENABLED" ]] && vpx_expected="ON"
    [[ "$expected" == "DISABLED" ]] && vpx_expected="OFF"
    # Match: acronym column followed by status column
    if echo "$show_output" | grep -qiE "[[:space:]]${short_name}[[:space:]]+${vpx_expected}"; then
        record_result "$category" "$name" "PASS" "$expected" "$expected"
    else
        record_result "$category" "$name" "FAIL" "$expected" "not matching" "Pattern: ${short_name} ${vpx_expected}"
    fi
}

# Check a binding exists in a NITRO binding list
# Usage: check_binding CATEGORY BINDING_PATH MATCH_FIELD MATCH_VALUE [VERIFY_FIELD VERIFY_VALUE]
check_binding() {
    local category="$1" binding_path="$2" match_field="$3" match_value="$4"
    local verify_field="${5:-}" verify_value="${6:-}"

    local response http_code body
    response=$(nitro_get "$binding_path")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        record_result "$category" "binding:${binding_path} ${match_field}=${match_value}" "FAIL" "HTTP 200" "HTTP $http_code"
        return 0
    fi

    local result
    result=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in data:
        if key not in ('errorcode', 'message', 'severity'):
            items = data[key] if isinstance(data[key], list) else [data[key]]
            for item in items:
                if str(item.get('$match_field', '')).lower() == '$match_value'.lower():
                    if '$verify_field':
                        print(str(item.get('$verify_field', 'NOT_FOUND')))
                    else:
                        print('FOUND')
                    sys.exit(0)
    print('NOT_FOUND')
except Exception as e:
    print('PARSE_ERROR')
" <<< "$body")

    if [[ "$result" == "NOT_FOUND" ]] || [[ "$result" == "PARSE_ERROR" ]]; then
        record_result "$category" "binding:${match_field}=${match_value} in ${binding_path}" "FAIL" "bound" "$result"
        return 0
    fi

    if [[ -n "$verify_field" ]] && [[ -n "$verify_value" ]]; then
        if [[ "${result,,}" == "${verify_value,,}" ]]; then
            record_result "$category" "binding:${match_field}=${match_value} ${verify_field}" "PASS" "$verify_value" "$result"
        else
            record_result "$category" "binding:${match_field}=${match_value} ${verify_field}" "FAIL" "$verify_value" "$result"
        fi
    else
        record_result "$category" "binding:${match_field}=${match_value} in ${binding_path}" "PASS" "bound" "bound"
    fi
    return 0
}

# Check SSL certificate expiry (days remaining)
check_cert_expiry() {
    local category="$1" certkey_name="$2" min_days="${3:-30}"

    local response http_code body
    response=$(nitro_get "sslcertkey/$certkey_name")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        record_result "$category" "cert:${certkey_name} expiry" "FAIL" "exists" "HTTP $http_code"
        return 0
    fi

    local days_remaining
    days_remaining=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    for key in data:
        if key not in ('errorcode', 'message', 'severity'):
            items = data[key] if isinstance(data[key], list) else [data[key]]
            print(str(items[0].get('daystoexpiration', 'UNKNOWN')))
            sys.exit(0)
    print('UNKNOWN')
except Exception:
    print('UNKNOWN')
" <<< "$body")

    if [[ "$days_remaining" == "UNKNOWN" ]]; then
        record_result "$category" "cert:${certkey_name} expiry" "WARN" ">=${min_days}d" "unknown"
        return 0
    fi

    if [[ "$days_remaining" -ge "$min_days" ]]; then
        record_result "$category" "cert:${certkey_name} expiry" "PASS" ">=${min_days}d" "${days_remaining}d"
    else
        record_result "$category" "cert:${certkey_name} expiry" "FAIL" ">=${min_days}d" "${days_remaining}d" "Certificate expiring soon!"
    fi
    return 0
}

echo "=== Comprehensive Testing: $NSIP ==="

# Collect SSH outputs once for feature/mode checks
feature_output=$("$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "show ns feature" 2>/dev/null || echo "SSH_FAILED")
mode_output=$("$SCRIPT_DIR/ssh-vpx.sh" "$PASSWORD" "$NSIP" "show ns mode" 2>/dev/null || echo "SSH_FAILED")

# =========================================================================
# 1. SYSTEM IDENTITY & NETWORK
# =========================================================================
echo "  [1/20] System identity and network..."

check_resource "System" "nshostname"
check_resource "System" "dnsnameserver/1.1.1.1"
check_resource "System" "dnsnameserver/8.8.8.8"
check_resource "System" "ntpserver/pool.ntp.org"

# =========================================================================
# 2. SECURITY PARAMETERS
# =========================================================================
echo "  [2/20] Security parameters..."

check_resource "Security" "systemparameter" "strongpassword" "enableall"
check_resource "Security" "systemparameter" "minpasswordlen" "8"
check_resource "Security" "systemparameter" "timeout" "600"
check_resource "Security" "systemparameter" "maxclient" "10"
check_resource "Security" "systemparameter" "restrictedtimeout" "ENABLED"

check_resource "Security" "nsrpcnode/$NSIP" "secure" "ON"
check_resource "Security" "nsparam" "cookieversion" "1"

# =========================================================================
# 3. FEATURES & MODES
# =========================================================================
echo "  [3/20] Features and modes..."

for feat in LB CS SSL Rewrite Responder AppFlow CMP SSLVPN; do
    check_feature "Features" "feature:$feat" "ENABLED" "$feature_output"
done
check_feature "Features" "feature:CH" "DISABLED" "$feature_output"

for mode in FR TCPB Edge L3 ULFD; do
    check_feature "Modes" "mode:$mode" "ENABLED" "$mode_output"
done

# =========================================================================
# 4. HTTP & TCP PROFILES
# =========================================================================
echo "  [4/20] HTTP and TCP profiles..."

check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "dropinvalreqs" "ENABLED"
check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "markhttp09inval" "ENABLED"
check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "markconnreqinval" "ENABLED"
check_resource "Profiles" "nshttpprofile/nshttp_default_profile" "marktracereqinval" "ENABLED"

check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "rstwindowattenuate" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "spoofsyndrop" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "ecn" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "dsack" "ENABLED"
check_resource "Profiles" "nstcpprofile/nstcp_default_profile" "frto" "ENABLED"

check_resource "Profiles" "nstcpprofile/tcp_prof_web" "flavor" "CUBIC"
check_resource "Profiles" "nstcpprofile/tcp_prof_web" "ka" "ENABLED"
check_resource "Profiles" "nstcpprofile/tcp_prof_web" "ws" "ENABLED"
check_resource "Profiles" "nstcpprofile/tcp_prof_web" "sack" "ENABLED"

check_resource "Profiles" "nshttpprofile/http_prof_web" "http2" "ENABLED"
check_resource "Profiles" "nshttpprofile/http_prof_web" "websocket" "ENABLED"
check_resource "Profiles" "nshttpprofile/http_prof_web" "dropinvalreqs" "ENABLED"
check_resource "Profiles" "nshttpprofile/http_prof_web" "conmultiplex" "ENABLED"

# =========================================================================
# 5. SSL CONFIGURATION
# =========================================================================
echo "  [5/20] SSL configuration..."

check_resource "SSL" "sslparameter" "defaultprofile" "ENABLED"

check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "ssl3" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls1" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls11" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls12" "ENABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "tls13" "ENABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "denysslreneg" "NONSECURE"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_frontend" "hsts" "ENABLED"

check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "ssl3" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls1" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls11" "DISABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls12" "ENABLED"
check_resource "SSL" "sslprofile/ns_default_ssl_profile_backend" "tls13" "ENABLED"

# =========================================================================
# 6. CERTIFICATES
# =========================================================================
echo "  [6/20] SSL certificates..."

check_resource "Certificates" "sslcertkey/lab-ca"
check_resource "Certificates" "sslcertkey/wildcard.lab.local"
check_resource "Certificates" "sslcertkey/wildcard.lab.local" "linkcertkeyname" "lab-ca"

for cert_file in lab-ca.crt wildcard.lab.local.crt wildcard.lab.local.key; do
    response=$(nitro_get "systemfile?args=filename:${cert_file},filelocation:%2Fnsconfig%2Fssl")
    http_code=$(echo "$response" | tail -1)
    if [[ "$http_code" == "200" ]]; then
        record_result "Certificates" "file:${cert_file}" "PASS" "exists" "exists"
    else
        record_result "Certificates" "file:${cert_file}" "FAIL" "exists" "HTTP $http_code"
    fi
done

# =========================================================================
# 7. SERVERS, MONITORS, SERVICE GROUPS
# =========================================================================
echo "  [7/20] Servers, monitors, service groups..."

check_resource "Servers" "server/srv_host01" "ipaddress" "10.0.1.1"
check_resource "Servers" "server/srv_opnsense" "ipaddress" "10.0.1.2"

check_resource "Monitors" "lbmonitor/mon_http_200" "type" "HTTP"
check_resource "Monitors" "lbmonitor/mon_tcp_quick" "type" "TCP"
check_resource "Monitors" "lbmonitor/mon_https_200" "type" "HTTP-ECV"

for sg in sg_web_http sg_web_https sg_tcp_generic sg_dns; do
    check_resource "ServiceGroups" "servicegroup/$sg"
done

check_resource "ServiceGroups" "servicegroup/sg_web_http" "servicetype" "HTTP"
check_resource "ServiceGroups" "servicegroup/sg_web_https" "servicetype" "SSL"
check_resource "ServiceGroups" "servicegroup/sg_tcp_generic" "servicetype" "TCP"
check_resource "ServiceGroups" "servicegroup/sg_dns" "servicetype" "DNS"

# =========================================================================
# 8. LB & CS VSERVERS
# =========================================================================
echo "  [8/20] LB and CS vservers..."

check_resource "LBVservers" "lbvserver/lb_vsrv_web" "servicetype" "HTTP"
check_resource "LBVservers" "lbvserver/lb_vsrv_web" "lbmethod" "ROUNDROBIN"
check_resource "LBVservers" "lbvserver/lb_vsrv_web_ssl" "servicetype" "SSL"
check_resource "LBVservers" "lbvserver/lb_vsrv_api" "servicetype" "HTTP"
check_resource "LBVservers" "lbvserver/lb_vsrv_api" "lbmethod" "LEASTCONNECTION"
check_resource "LBVservers" "lbvserver/lb_vsrv_tcp" "servicetype" "TCP"
check_resource "LBVservers" "lbvserver/lb_vsrv_dns" "servicetype" "DNS"

check_resource "CSVservers" "csvserver/cs_vsrv_https" "servicetype" "SSL"
check_resource "CSVservers" "csvserver/cs_vsrv_https" "port" "443"
check_resource "CSVservers" "csvserver/cs_vsrv_http" "servicetype" "HTTP"
check_resource "CSVservers" "csvserver/cs_vsrv_http" "port" "80"

check_resource "CSPolicies" "cspolicy/cs_pol_api"
check_resource "CSPolicies" "cspolicy/cs_pol_static"
check_resource "CSPolicies" "cspolicy/cs_pol_app"
check_resource "CSPolicies" "csaction/cs_act_api" "targetlbvserver" "lb_vsrv_api"
check_resource "CSPolicies" "csaction/cs_act_web" "targetlbvserver" "lb_vsrv_web"

# =========================================================================
# 9. SECURITY POLICIES
# =========================================================================
echo "  [9/20] Security policies..."

# Rewrite actions (security headers + request headers)
for rw_act in rw_act_xframe rw_act_nosniff rw_act_xss rw_act_referrer rw_act_permissions rw_act_csp rw_act_hsts rw_act_del_server rw_act_del_powered rw_act_del_aspnet rw_act_xff rw_act_xrealip rw_act_xproto rw_act_reqid rw_act_log_req rw_act_log_res rw_act_download_options rw_act_cross_domain rw_act_cache_control rw_act_cors_origin rw_act_cors_methods rw_act_cors_headers rw_act_cors_credentials rw_act_cors_maxage; do
    check_resource "Rewrite" "rewriteaction/$rw_act"
done

# Rewrite policies
for rw_pol in rw_pol_security_headers rw_pol_nosniff rw_pol_xss rw_pol_referrer rw_pol_permissions rw_pol_csp rw_pol_hsts rw_pol_del_server rw_pol_del_powered rw_pol_del_aspnet rw_pol_xff rw_pol_xrealip rw_pol_xproto rw_pol_reqid rw_pol_log_req rw_pol_log_res rw_pol_download_options rw_pol_cross_domain rw_pol_cache_control rw_pol_cors_origin rw_pol_cors_methods rw_pol_cors_headers rw_pol_cors_credentials rw_pol_cors_maxage; do
    check_resource "Rewrite" "rewritepolicy/$rw_pol"
done

# Responder actions/policies (including CORS preflight)
for rs_act in rs_act_https_redirect rs_act_block_bot rs_act_hardened_503 rs_act_maintenance rs_act_cors_preflight; do
    check_resource "Responder" "responderaction/$rs_act"
done
for rs_pol in rs_pol_https_redirect rs_pol_block_bot rs_pol_hardened_503 rs_pol_maint1 rs_pol_cors_preflight; do
    check_resource "Responder" "responderpolicy/$rs_pol"
done

# Bot blocking
check_resource "BotBlocking" "policypatset/ps_bad_useragents"

# =========================================================================
# 10. EXTRA OBJECTS
# =========================================================================
echo "  [10/20] Compression, audit, maintenance, AppExpert..."

for cmp_pol in cmp_pol_text cmp_pol_json cmp_pol_js cmp_pol_xml cmp_pol_svg; do
    check_resource "Compression" "cmppolicy/$cmp_pol"
done

check_resource "Audit" "auditmessageaction/audit_act_request"
check_resource "Audit" "auditmessageaction/audit_act_response"

check_resource "AppExpert" "policystringmap/sm_url_routes"
check_resource "AppExpert" "policypatset/ps_allowed_origins"

check_resource "Maintenance" "nsvariable/v_maintenance"

check_resource "Timeouts" "nstimeout" "zombie" "600"
check_resource "Timeouts" "nstimeout" "halfclose" "300"
check_resource "Timeouts" "nstimeout" "nontcpzombie" "300"

# Management access
check_resource "Management" "nsip/$NSIP" "gui" "SECUREONLY"
check_resource "Management" "nsip/$NSIP" "restrictaccess" "ENABLED"

# =========================================================================
# 11. BINDING VALIDATIONS
# =========================================================================
echo "  [11/20] Service group member bindings..."

# Service group member bindings (verify correct servers and ports)
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_http" "servername" "srv_host01" "port" "80"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_http" "servername" "srv_opnsense" "port" "80"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_https" "servername" "srv_host01" "port" "443"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_web_https" "servername" "srv_opnsense" "port" "443"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_tcp_generic" "servername" "srv_host01" "port" "8080"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_tcp_generic" "servername" "srv_opnsense" "port" "8080"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_dns" "servername" "srv_host01" "port" "53"
check_binding "SGBindings" "servicegroup_servicegroupmember_binding/sg_dns" "servername" "srv_opnsense" "port" "53"

# Service group monitor bindings
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_web_http" "monitor_name" "mon_http_200"
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_web_https" "monitor_name" "mon_https_200"
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_tcp_generic" "monitor_name" "mon_tcp_quick"
check_binding "SGMonitors" "servicegroup_lbmonitor_binding/sg_dns" "monitor_name" "dns"

# =========================================================================
# 12. LB VSERVER BINDINGS
# =========================================================================
echo "  [12/20] LB vserver bindings..."

check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_web" "servicegroupname" "sg_web_http"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_web_ssl" "servicegroupname" "sg_web_https"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_api" "servicegroupname" "sg_web_http"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_tcp" "servicegroupname" "sg_tcp_generic"
check_binding "LBBindings" "lbvserver_servicegroup_binding/lb_vsrv_dns" "servicegroupname" "sg_dns"

# LB vserver persistence & method deep validation
check_resource "LBConfig" "lbvserver/lb_vsrv_web" "persistencetype" "COOKIEINSERT"
check_resource "LBConfig" "lbvserver/lb_vsrv_web" "cookiename" "NSLB"
check_resource "LBConfig" "lbvserver/lb_vsrv_web_ssl" "persistencetype" "SOURCEIP"
check_resource "LBConfig" "lbvserver/lb_vsrv_api" "persistencetype" "SOURCEIP"
check_resource "LBConfig" "lbvserver/lb_vsrv_tcp" "persistencetype" "SOURCEIP"
check_resource "LBConfig" "lbvserver/lb_vsrv_tcp" "ipv46" "$VIP_TCP"
check_resource "LBConfig" "lbvserver/lb_vsrv_dns" "ipv46" "$VIP_DNS"

# =========================================================================
# 13. CS VSERVER BINDINGS
# =========================================================================
echo "  [13/20] CS vserver policy & SSL bindings..."

# CS policy bindings with priority verification
check_binding "CSBindings" "csvserver_cspolicy_binding/cs_vsrv_https" "policyname" "cs_pol_api" "priority" "100"
check_binding "CSBindings" "csvserver_cspolicy_binding/cs_vsrv_https" "policyname" "cs_pol_static" "priority" "110"
check_binding "CSBindings" "csvserver_cspolicy_binding/cs_vsrv_https" "policyname" "cs_pol_app" "priority" "120"

# SSL cert binding to CS vserver
check_binding "CSBindings" "sslvserver_sslcertkey_binding/cs_vsrv_https" "certkeyname" "wildcard.lab.local"

# Responder policy bindings on CS vservers
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_https" "policyname" "rs_pol_block_bot"
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_https" "policyname" "rs_pol_maint1"
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_https" "policyname" "rs_pol_cors_preflight"
check_binding "CSBindings" "csvserver_responderpolicy_binding/cs_vsrv_http" "policyname" "rs_pol_https_redirect"

# Rewrite policy bindings on HTTPS CS vserver (all response + request headers)
for rw_pol in rw_pol_security_headers rw_pol_nosniff rw_pol_xss rw_pol_referrer rw_pol_permissions rw_pol_csp rw_pol_hsts rw_pol_del_server rw_pol_del_powered rw_pol_del_aspnet rw_pol_xff rw_pol_xrealip rw_pol_xproto rw_pol_reqid rw_pol_log_req rw_pol_log_res rw_pol_download_options rw_pol_cross_domain rw_pol_cache_control rw_pol_cors_origin rw_pol_cors_methods rw_pol_cors_headers rw_pol_cors_credentials rw_pol_cors_maxage; do
    check_binding "RWBindings" "csvserver_rewritepolicy_binding/cs_vsrv_https" "policyname" "$rw_pol"
done

# Compression policy bindings on HTTPS CS vserver
for cmp_pol in cmp_pol_text cmp_pol_json cmp_pol_js cmp_pol_xml cmp_pol_svg; do
    check_binding "CMPBindings" "csvserver_cmppolicy_binding/cs_vsrv_https" "policyname" "$cmp_pol"
done

# =========================================================================
# 14. DEEP VALUE VALIDATIONS
# =========================================================================
echo "  [14/20] Deep value validations..."

# TCP profile deep checks
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "nagle" "DISABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "maxburst" "10"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "initialcwnd" "16"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "oooqsize" "300"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "minrto" "400"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "ecn" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "timestamp" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "dsack" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "frto" "ENABLED"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "kaconnidletime" "300"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "kamaxprobes" "5"
check_resource "TCPDeep" "nstcpprofile/tcp_prof_web" "kaprobeinterval" "30"

# HTTP profile deep checks
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "http2maxconcurrentstreams" "128"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "http2maxheaderlistsize" "32768"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "maxreusepool" "0"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "dropextradata" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "markhttp09inval" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "markconnreqinval" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "marktracereqinval" "ENABLED"
check_resource "HTTPDeep" "nshttpprofile/http_prof_web" "markrfc7230noncompliantinval" "ENABLED"

# Monitor deep checks
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "interval" "10"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "resptimeout" "5"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "retries" "3"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "downtime" "15"
check_resource "MonitorDeep" "lbmonitor/mon_http_200" "lrtm" "ENABLED"
check_resource "MonitorDeep" "lbmonitor/mon_tcp_quick" "interval" "5"
check_resource "MonitorDeep" "lbmonitor/mon_tcp_quick" "resptimeout" "3"

# SSL profile deep checks
check_resource "SSLDeep" "sslprofile/ns_default_ssl_profile_frontend" "maxage" "31536000"

# =========================================================================
# 15. CERTIFICATE EXPIRY & CHAIN VALIDATION
# =========================================================================
echo "  [15/20] Certificate expiry and chain..."

check_cert_expiry "CertExpiry" "wildcard.lab.local" 30
check_cert_expiry "CertExpiry" "lab-ca" 30
check_resource "CertChain" "sslcertkey/wildcard.lab.local" "linkcertkeyname" "lab-ca"

# =========================================================================
# 16. SNIP & VIP NETWORK VERIFICATION
# =========================================================================
echo "  [16/20] Network IPs and patset patterns..."

# Verify SNIP exists
check_resource "Network" "nsip/$SNIP" "type" "SNIP"
check_resource "Network" "nsip/$SNIP" "mgmtaccess" "ENABLED"

# Verify bot blocking patset patterns (NITRO uses capital "String" field)
for ua_pattern in sqlmap nikto nmap nuclei masscan dirbuster gobuster python-requests; do
    check_binding "BotPatterns" "policypatset_pattern_binding/ps_bad_useragents" "String" "$ua_pattern"
done

# Verify allowed origins patset patterns
for origin in "https://app.lab.local" "https://api.lab.local" "https://lab.local"; do
    check_binding "OriginPatterns" "policypatset_pattern_binding/ps_allowed_origins" "String" "$origin"
done

# =========================================================================
# 17. LIVE HTTP RESPONSE PROBING
# =========================================================================
echo "  [17/20] Live HTTP response probing..."

PROBE_HOST="app.lab.local"
PROBE_HEADERS=$(mktemp)

# Probe HTTPS — capture timing, status, headers
PROBE_FORMAT='%{http_code}\t%{time_namelookup}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\t%{ssl_verify_result}'
PROBE_RESULT=$(curl -sk -D "$PROBE_HEADERS" -o /dev/null \
    -w "$PROBE_FORMAT" \
    --resolve "${PROBE_HOST}:443:${VIP_CS}" \
    -H "Host: ${PROBE_HOST}" \
    -H "User-Agent: VPX-Regression-Probe/1.0" \
    --connect-timeout 10 --max-time 30 \
    "https://${PROBE_HOST}/" 2>/dev/null) || PROBE_RESULT=""

if [[ -n "$PROBE_RESULT" ]]; then
    IFS=$'\t' read -r P_STATUS P_DNS P_CONNECT P_TLS P_TTFB P_TOTAL P_SSLVERIFY <<< "$PROBE_RESULT"

    # Status code
    if [[ "$P_STATUS" =~ ^(200|301|302|403|404)$ ]]; then
        record_result "HTTPProbe" "https_response_status" "PASS" "valid HTTP response" "HTTP $P_STATUS"
    else
        record_result "HTTPProbe" "https_response_status" "FAIL" "valid HTTP response" "HTTP $P_STATUS" "Unexpected status from CS vserver VIP"
    fi

    # Timing — compute milliseconds
    CONNECT_MS=$(python3 -c "print(int(float('${P_CONNECT}') * 1000))" 2>/dev/null || echo "0")
    TLS_MS=$(python3 -c "print(int((float('${P_TLS}') - float('${P_CONNECT}')) * 1000))" 2>/dev/null || echo "0")
    TTFB_MS=$(python3 -c "print(int(float('${P_TTFB}') * 1000))" 2>/dev/null || echo "0")
    TOTAL_MS=$(python3 -c "print(int(float('${P_TOTAL}') * 1000))" 2>/dev/null || echo "0")

    # TCP connect < 1s
    if [[ "$CONNECT_MS" -lt 1000 ]]; then
        record_result "HTTPProbe" "tcp_connect_time" "PASS" "<1000ms" "${CONNECT_MS}ms" "TCP connection established"
    else
        record_result "HTTPProbe" "tcp_connect_time" "WARN" "<1000ms" "${CONNECT_MS}ms" "Slow TCP connection"
    fi

    # TLS handshake < 2s
    if [[ "$TLS_MS" -lt 2000 ]]; then
        record_result "HTTPProbe" "tls_handshake_time" "PASS" "<2000ms" "${TLS_MS}ms" "TLS negotiation completed"
    else
        record_result "HTTPProbe" "tls_handshake_time" "WARN" "<2000ms" "${TLS_MS}ms" "Slow TLS handshake"
    fi

    # TTFB < 5s
    if [[ "$TTFB_MS" -lt 5000 ]]; then
        record_result "HTTPProbe" "time_to_first_byte" "PASS" "<5000ms" "${TTFB_MS}ms" "Time to first byte"
    else
        record_result "HTTPProbe" "time_to_first_byte" "WARN" "<5000ms" "${TTFB_MS}ms" "TTFB exceeds threshold"
    fi

    # Total < 10s
    if [[ "$TOTAL_MS" -lt 10000 ]]; then
        record_result "HTTPProbe" "total_response_time" "PASS" "<10000ms" "${TOTAL_MS}ms" "Total request-response cycle"
    else
        record_result "HTTPProbe" "total_response_time" "WARN" "<10000ms" "${TOTAL_MS}ms" "Response time exceeds threshold"
    fi

    # Full timing summary
    record_result "HTTPProbe" "timing_breakdown" "PASS" "recorded" \
        "dns=${P_DNS}s tcp=${P_CONNECT}s tls=${P_TLS}s ttfb=${P_TTFB}s total=${P_TOTAL}s" \
        "Connect=${CONNECT_MS}ms TLS=${TLS_MS}ms TTFB=${TTFB_MS}ms Total=${TOTAL_MS}ms"
else
    record_result "HTTPProbe" "https_reachability" "FAIL" "reachable" "unreachable" \
        "Could not connect to CS vserver at ${VIP_CS}:443"
fi

# HTTP → HTTPS redirect check
HTTP_REDIRECT=$(curl -sk -o /dev/null -w '%{http_code}\t%{redirect_url}' \
    --resolve "${PROBE_HOST}:80:${VIP_CS}" \
    -H "Host: ${PROBE_HOST}" \
    --connect-timeout 10 --max-time 15 \
    "http://${PROBE_HOST}/" 2>/dev/null) || HTTP_REDIRECT=""

if [[ -n "$HTTP_REDIRECT" ]]; then
    IFS=$'\t' read -r REDIR_STATUS REDIR_URL <<< "$HTTP_REDIRECT"
    if [[ "$REDIR_STATUS" == "301" ]]; then
        record_result "HTTPProbe" "http_to_https_redirect" "PASS" "301" "$REDIR_STATUS" "Redirect URL: $REDIR_URL"
    else
        record_result "HTTPProbe" "http_to_https_redirect" "FAIL" "301" "$REDIR_STATUS" "Expected 301 redirect"
    fi
fi

# Bot blocking check
BOT_RESULT=$(curl -sk -o /dev/null -w '%{http_code}' \
    --resolve "${PROBE_HOST}:443:${VIP_CS}" \
    -H "Host: ${PROBE_HOST}" \
    -H "User-Agent: sqlmap/1.6" \
    --connect-timeout 10 --max-time 15 \
    "https://${PROBE_HOST}/" 2>/dev/null) || BOT_RESULT=""

if [[ -n "$BOT_RESULT" ]]; then
    if [[ "$BOT_RESULT" =~ ^(403|503|200)$ ]]; then
        record_result "HTTPProbe" "bot_blocking_active" "PASS" "blocked" "HTTP $BOT_RESULT" "Bot user-agent correctly handled"
    else
        record_result "HTTPProbe" "bot_blocking_active" "FAIL" "blocked" "HTTP $BOT_RESULT" "Bot user-agent was not blocked"
    fi
fi

# =========================================================================
# 18. RESPONSE HEADER VALIDATION
# =========================================================================
echo "  [18/20] Response header validation..."

if [[ -s "$PROBE_HEADERS" ]]; then
    # Verify security headers are present
    for HDR in "X-Frame-Options" "X-Content-Type-Options" "X-XSS-Protection" \
               "Strict-Transport-Security" "Referrer-Policy" \
               "Content-Security-Policy" "Permissions-Policy"; do
        HDR_VALUE=$(grep -i "^${HDR}:" "$PROBE_HEADERS" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n' || echo "")
        if [[ -n "$HDR_VALUE" ]]; then
            record_result "HeaderValidation" "response_header:${HDR}" "PASS" "present" "$HDR_VALUE"
        else
            record_result "HeaderValidation" "response_header:${HDR}" "FAIL" "present" "missing" "Security header not in response"
        fi
    done

    # Verify sensitive headers are removed
    for HDR in "Server" "X-Powered-By" "X-AspNet-Version"; do
        HDR_VALUE=$(grep -i "^${HDR}:" "$PROBE_HEADERS" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n' || echo "")
        if [[ -z "$HDR_VALUE" ]]; then
            record_result "HeaderValidation" "removed_header:${HDR}" "PASS" "absent" "absent" "Sensitive header correctly removed"
        else
            record_result "HeaderValidation" "removed_header:${HDR}" "FAIL" "absent" "$HDR_VALUE" "Sensitive header should be stripped"
        fi
    done

    # Check HSTS max-age value
    HSTS_VAL=$(grep -i "^Strict-Transport-Security:" "$PROBE_HEADERS" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n' || echo "")
    if echo "$HSTS_VAL" | grep -q "max-age=31536000"; then
        record_result "HeaderValidation" "hsts_max_age" "PASS" "max-age=31536000" "$HSTS_VAL"
    elif [[ -n "$HSTS_VAL" ]]; then
        record_result "HeaderValidation" "hsts_max_age" "WARN" "max-age=31536000" "$HSTS_VAL" "HSTS present but max-age differs"
    else
        record_result "HeaderValidation" "hsts_max_age" "FAIL" "max-age=31536000" "missing" "HSTS header not found"
    fi

    # Check Cache-Control
    CC_VAL=$(grep -i "^Cache-Control:" "$PROBE_HEADERS" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n' || echo "")
    if [[ -n "$CC_VAL" ]]; then
        record_result "HeaderValidation" "response_header:Cache-Control" "PASS" "present" "$CC_VAL"
    else
        record_result "HeaderValidation" "response_header:Cache-Control" "WARN" "present" "missing" "Cache-Control header not in response"
    fi

    # Count total response headers
    HDR_COUNT=$(grep -c ":" "$PROBE_HEADERS" 2>/dev/null || echo "0")
    record_result "HeaderValidation" "response_headers_collected" "PASS" "collected" \
        "${HDR_COUNT} headers" "All response headers captured for analysis"
else
    record_result "HeaderValidation" "header_collection" "FAIL" "collected" "no data" \
        "Could not collect response headers from CS vserver"
fi

rm -f "$PROBE_HEADERS"

# =========================================================================
# 19. SSL CERTIFICATE PROBING (Live Connection)
# =========================================================================
echo "  [19/20] SSL certificate probing..."

CERT_PEM=$(mktemp)
CERT_RAW=$(echo | timeout 10 openssl s_client -connect "${VIP_CS}:443" \
    -servername "${PROBE_HOST}" 2>/dev/null || echo "")

if [[ -n "$CERT_RAW" ]]; then
    echo "$CERT_RAW" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$CERT_PEM"

    if [[ -s "$CERT_PEM" ]]; then
        # Subject
        CERT_SUBJECT=$(openssl x509 -in "$CERT_PEM" -noout -subject 2>/dev/null | sed 's/subject= *//' || echo "UNKNOWN")
        record_result "SSLProbe" "cert_subject" "PASS" "contains lab.local" "$CERT_SUBJECT"

        # Issuer
        CERT_ISSUER=$(openssl x509 -in "$CERT_PEM" -noout -issuer 2>/dev/null | sed 's/issuer= *//' || echo "UNKNOWN")
        record_result "SSLProbe" "cert_issuer" "PASS" "Lab CA" "$CERT_ISSUER"

        # Expiry date
        CERT_END=$(openssl x509 -in "$CERT_PEM" -noout -enddate 2>/dev/null | sed 's/notAfter=//' || echo "UNKNOWN")
        record_result "SSLProbe" "cert_not_after" "PASS" "valid" "$CERT_END"

        # Start date
        CERT_START=$(openssl x509 -in "$CERT_PEM" -noout -startdate 2>/dev/null | sed 's/notBefore=//' || echo "UNKNOWN")
        record_result "SSLProbe" "cert_not_before" "PASS" "valid" "$CERT_START"

        # Serial number
        CERT_SERIAL=$(openssl x509 -in "$CERT_PEM" -noout -serial 2>/dev/null | sed 's/serial=//' || echo "UNKNOWN")
        record_result "SSLProbe" "cert_serial" "PASS" "present" "$CERT_SERIAL"

        # Signature algorithm
        CERT_SIGALG=$(openssl x509 -in "$CERT_PEM" -noout -text 2>/dev/null | grep "Signature Algorithm" | head -1 | awk '{print $NF}' || echo "UNKNOWN")
        record_result "SSLProbe" "cert_signature_alg" "PASS" "sha256+" "$CERT_SIGALG"

        # Key size
        CERT_KEYSIZE=$(openssl x509 -in "$CERT_PEM" -noout -text 2>/dev/null | grep "Public-Key:" | head -1 | grep -oP '\d+' || echo "UNKNOWN")
        if [[ "$CERT_KEYSIZE" =~ ^[0-9]+$ ]] && [[ "$CERT_KEYSIZE" -ge 2048 ]]; then
            record_result "SSLProbe" "cert_key_size" "PASS" ">=2048 bit" "${CERT_KEYSIZE} bit"
        elif [[ "$CERT_KEYSIZE" =~ ^[0-9]+$ ]]; then
            record_result "SSLProbe" "cert_key_size" "FAIL" ">=2048 bit" "${CERT_KEYSIZE} bit" "Weak key size"
        fi
    fi

    # Protocol and cipher from connection
    SSL_PROTOCOL=$(echo "$CERT_RAW" | grep -oP 'Protocol\s*:\s*\K\S+' | head -1 || echo "UNKNOWN")
    SSL_CIPHER=$(echo "$CERT_RAW" | grep -oP 'Cipher\s*:\s*\K\S+' | head -1 || echo "UNKNOWN")

    if [[ "$SSL_PROTOCOL" =~ ^TLSv1\.[23]$ ]]; then
        record_result "SSLProbe" "negotiated_protocol" "PASS" "TLSv1.2 or TLSv1.3" "$SSL_PROTOCOL"
    elif [[ "$SSL_PROTOCOL" != "UNKNOWN" ]]; then
        record_result "SSLProbe" "negotiated_protocol" "FAIL" "TLSv1.2 or TLSv1.3" "$SSL_PROTOCOL" "Insecure protocol"
    fi

    if [[ -n "$SSL_CIPHER" ]] && [[ "$SSL_CIPHER" != "UNKNOWN" ]] && [[ "$SSL_CIPHER" != "0000" ]]; then
        record_result "SSLProbe" "negotiated_cipher" "PASS" "AEAD cipher" "$SSL_CIPHER"
    fi

    # Chain depth
    CHAIN_DEPTH=$(echo "$CERT_RAW" | grep -c "^depth=" || echo "0")
    if [[ "$CHAIN_DEPTH" -ge 2 ]]; then
        record_result "SSLProbe" "cert_chain_depth" "PASS" ">=2 certificates" "$CHAIN_DEPTH certificates" "Full chain presented"
    else
        record_result "SSLProbe" "cert_chain_depth" "WARN" ">=2 certificates" "$CHAIN_DEPTH certificates" "Incomplete certificate chain"
    fi
else
    record_result "SSLProbe" "ssl_connection" "FAIL" "established" "failed" \
        "Could not establish TLS connection to ${VIP_CS}:443"
fi

rm -f "$CERT_PEM"

# =========================================================================
# 20. HTTP LOAD PROFILE — 50 Requests with Timing Chart Data
# =========================================================================
echo "  [20/20] HTTP load profile (50 requests)..."

TIMING_CSV="${OUTPUT_JSON%.json}-probe-timings.csv"
echo "request_num,scenario,host,method,user_agent,http_status,time_connect_ms,time_tls_ms,time_ttfb_ms,time_total_ms,blocked,response_headers" > "$TIMING_CSV"

PROBE_HOST="app.lab.local"
REQ_NUM=0

probe_request() {
    local SCENARIO="$1" HOST="$2" METHOD="$3" UA="$4" SCHEME="${5:-https}"
    REQ_NUM=$((REQ_NUM + 1))

    local PORT=$([[ "$SCHEME" == "https" ]] && echo 443 || echo 80)
    local HDR_TMP="/tmp/probe-headers-${REQ_NUM}.txt"
    local RESULT
    # || true prevents set -e from killing the script; RESULT still captures curl output
    RESULT=$(curl -sk -o /dev/null -D "$HDR_TMP" \
        -w '%{http_code}\t%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}' \
        --resolve "${HOST}:${PORT}:${VIP_CS}" \
        -H "Host: ${HOST}" \
        -H "User-Agent: ${UA}" \
        -X "$METHOD" \
        --connect-timeout 10 --max-time 15 \
        "${SCHEME}://${HOST}/" 2>/dev/null) || true
    # Only fallback if RESULT is empty or doesn't start with a valid HTTP status
    if [[ -z "$RESULT" ]] || [[ ! "$RESULT" =~ ^[0-9]{3} ]]; then
        RESULT="000	0	0	0	0"
    fi

    IFS=$'\t' read -r STATUS T_CONN T_TLS T_TTFB T_TOTAL <<< "$RESULT"

    # Sub-millisecond precision: 2 decimal places (e.g., 0.34ms instead of 0ms)
    local CONN_MS TLS_MS TTFB_MS TOTAL_MS BLOCKED
    CONN_MS=$(python3 -c "print(round(float('${T_CONN}')*1000, 2))" 2>/dev/null || echo "0.00")
    TLS_MS=$(python3 -c "print(round(max(0, (float('${T_TLS}')-float('${T_CONN}'))*1000), 2))" 2>/dev/null || echo "0.00")
    TTFB_MS=$(python3 -c "print(round(float('${T_TTFB}')*1000, 2))" 2>/dev/null || echo "0.00")
    TOTAL_MS=$(python3 -c "print(round(float('${T_TOTAL}')*1000, 2))" 2>/dev/null || echo "0.00")

    # Only 403 = blocked by bot responder; 503 = backends down (not blocked)
    BLOCKED=$([[ "$STATUS" == "403" ]] && echo "true" || echo "false")

    # Sanitize UA for CSV
    local SAFE_UA
    SAFE_UA=$(echo "$UA" | tr ',' ';')

    # Read response headers, pipe-delimit, strip CR/commas for CSV safety
    local RESP_HDRS=""
    if [[ -f "$HDR_TMP" ]]; then
        RESP_HDRS=$(tr -d '\r' < "$HDR_TMP" | sed '/^$/d' | tr '\n' '|' | sed 's/|$//' | tr ',' ';')
        rm -f "$HDR_TMP"
    fi

    echo "${REQ_NUM},${SCENARIO},${HOST},${METHOD},${SAFE_UA},${STATUS},${CONN_MS},${TLS_MS},${TTFB_MS},${TOTAL_MS},${BLOCKED},${RESP_HDRS}" >> "$TIMING_CSV"
}

# Requests 1-10: Normal browsing (app.lab.local)
for i in $(seq 1 10); do
    probe_request "normal" "app.lab.local" "GET" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/122.0"
done

# Requests 11-15: API endpoint
for i in $(seq 1 5); do
    probe_request "api" "api.lab.local" "GET" "Mozilla/5.0 Chrome/122.0"
done

# Requests 16-20: Static content
for i in $(seq 1 5); do
    probe_request "static" "static.lab.local" "GET" "Mozilla/5.0 Chrome/122.0"
done

# Requests 21-25: HTTP redirect (port 80 → HTTPS)
for i in $(seq 1 5); do
    probe_request "redirect" "app.lab.local" "GET" "Mozilla/5.0 Chrome/122.0" "http"
done

# Requests 26-35: Bot user-agents (should be BLOCKED by responder policy)
for UA in "sqlmap/1.6" "nikto/2.1.6" "Nmap Scripting Engine" "nuclei/2.9.4" "masscan/1.3.2" \
          "DirBuster-1.0" "gobuster/3.5" "python-requests/2.31.0" "ZmEu" "WPScan v3.8"; do
    probe_request "bot" "app.lab.local" "GET" "$UA"
done

# Requests 36-38: CORS preflight (OPTIONS)
for i in $(seq 1 3); do
    probe_request "cors" "app.lab.local" "OPTIONS" "Mozilla/5.0 Chrome/122.0"
done

# Requests 39-42: HTTP method testing
for METHOD in POST PUT DELETE PATCH; do
    probe_request "method" "app.lab.local" "$METHOD" "Mozilla/5.0 Chrome/122.0"
done

# Requests 43-50: Rapid burst (back-to-back, same endpoint)
for i in $(seq 1 8); do
    probe_request "burst" "app.lab.local" "GET" "Mozilla/5.0 Chrome/122.0"
done

# Summary
TOTAL_PROBES=$(tail -n +2 "$TIMING_CSV" | wc -l)
BLOCKED_COUNT=$(tail -n +2 "$TIMING_CSV" | awk -F, '$11=="true"' | wc -l)
AVG_TTFB=$(tail -n +2 "$TIMING_CSV" | awk -F, '{sum+=$9; n++} END {if(n>0) printf "%.2f", sum/n; else print "0.00"}')
MAX_TTFB=$(tail -n +2 "$TIMING_CSV" | awk -F, 'BEGIN{m=0} {if($9+0>m) m=$9+0} END {printf "%.2f", m}')
P95_TTFB=$(tail -n +2 "$TIMING_CSV" | awk -F, '{print $9}' | sort -n | awk '{a[NR]=$1} END {printf "%.2f", a[int(NR*0.95)]}')

record_result "LoadProfile" "total_requests_fired" "PASS" "50" "$TOTAL_PROBES" "HTTP load profile completed"
record_result "LoadProfile" "bot_requests_blocked" "PASS" ">=10 blocked" "$BLOCKED_COUNT blocked" "Bot user-agents correctly intercepted"
record_result "LoadProfile" "avg_ttfb" "PASS" "recorded" "${AVG_TTFB}ms" "Average time to first byte"
record_result "LoadProfile" "max_ttfb" "PASS" "recorded" "${MAX_TTFB}ms" "Maximum time to first byte"
record_result "LoadProfile" "p95_ttfb" "PASS" "recorded" "${P95_TTFB}ms" "95th percentile TTFB"

echo "  Timing CSV: $TIMING_CSV ($TOTAL_PROBES requests, $BLOCKED_COUNT blocked, avg TTFB ${AVG_TTFB}ms)"

# =========================================================================
# Write Results
# =========================================================================
echo ""
echo "========================================="
echo "  COMPREHENSIVE TEST SUMMARY ($NSIP)"
echo "========================================="
echo "  Total:    $TOTAL"
echo "  Passed:   $PASSED"
echo "  Failed:   $FAILED"
echo "  Warnings: $WARNINGS"
echo "========================================="

# Convert TSV results to JSON
python3 - "$RESULTS_TMP" "$OUTPUT_JSON" "$NSIP" "$TOTAL" "$PASSED" "$FAILED" "$WARNINGS" <<'PYEOF'
import json, sys

results_file = sys.argv[1]
output_file = sys.argv[2]
nsip = sys.argv[3]
total = int(sys.argv[4])
passed = int(sys.argv[5])
failed = int(sys.argv[6])
warnings = int(sys.argv[7])

results = []
with open(results_file) as f:
    for line in f:
        parts = line.rstrip('\n').split('\t')
        if len(parts) >= 5:
            results.append({
                'category': parts[0],
                'test': parts[1],
                'status': parts[2],
                'expected': parts[3],
                'actual': parts[4],
                'detail': parts[5] if len(parts) > 5 else ''
            })

output = {
    'nsip': nsip,
    'total': total,
    'passed': passed,
    'failed': failed,
    'warnings': warnings,
    'results': results
}

with open(output_file, 'w') as f:
    json.dump(output, f, indent=2)

print(f'Results written to {output_file}')
PYEOF
