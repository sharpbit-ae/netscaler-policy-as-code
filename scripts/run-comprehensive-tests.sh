#!/usr/bin/env bash
# run-comprehensive-tests.sh — Unified test suite for Azure VPX
# Tests: NITRO API validation, health checks, performance metrics, stress tests, SSL probing, bot blocking
# Usage: run-comprehensive-tests.sh MGMT_IP PASSWORD VIP
set -uo pipefail

MGMT_IP="${1:?Usage: $0 MGMT_IP PASSWORD VIP}"
PASSWORD="${2:?Missing PASSWORD}"
VIP="${3:?Missing VIP (public IP)}"

# =========================================================================
# TEST FRAMEWORK
# =========================================================================
TOTAL=0; PASSED=0; FAILED=0; WARNINGS=0

pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); printf "  %-6s %s\n" "PASS" "$1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); printf "  %-6s %s  [expected: %s, got: %s]\n" "FAIL" "$1" "$2" "$3"; }
warn() { TOTAL=$((TOTAL+1)); WARNINGS=$((WARNINGS+1)); printf "  %-6s %s  [%s]\n" "WARN" "$1" "$2"; }

section() { echo ""; echo "─── $1 ───"; }

# NITRO API helper
nitro() {
    local ep="$1"
    curl -sk -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" -H "X-NITRO-PASS: $PASSWORD" \
        "https://${MGMT_IP}/nitro/v1/config/${ep}" 2>/dev/null
}

nitro_stat() {
    local ep="$1"
    curl -sk -H "Content-Type: application/json" \
        -H "X-NITRO-USER: nsroot" -H "X-NITRO-PASS: $PASSWORD" \
        "https://${MGMT_IP}/nitro/v1/stat/${ep}" 2>/dev/null
}

# Extract field from NITRO JSON
field() {
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        v=d[k]
        items=v if isinstance(v,list) else [v]
        if items: print(str(items[0].get('$1','NOT_FOUND')))
        break
" 2>/dev/null
}

# Check NITRO resource exists and optionally verify a field
check() {
    local name="$1" path="$2" fld="${3:-}" expected="${4:-}"
    local body
    body=$(nitro "$path") || { fail "$name" "reachable" "error"; return; }
    local ec
    ec=$(echo "$body" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('errorcode',999))" 2>/dev/null || echo "999")
    if [[ "$ec" != "0" ]]; then fail "$name" "exists" "not found (ec=$ec)"; return; fi
    if [[ -z "$fld" ]]; then pass "$name"; return; fi
    local actual
    actual=$(echo "$body" | field "$fld")
    if [[ "${actual,,}" == "${expected,,}" ]]; then pass "$name ($fld=$actual)"
    else fail "$name ($fld)" "$expected" "$actual"; fi
}

echo "==========================================================================="
echo "  COMPREHENSIVE VPX TEST SUITE"
echo "  MGMT: ${MGMT_IP}  |  VIP: ${VIP}"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "==========================================================================="

# =========================================================================
# 1. NITRO API CONNECTIVITY
# =========================================================================
section "1. NITRO API Connectivity"

NITRO_RESP=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "X-NITRO-USER: nsroot" -H "X-NITRO-PASS: $PASSWORD" \
    "https://${MGMT_IP}/nitro/v1/config/nsversion" 2>/dev/null) || NITRO_RESP="000"
if [[ "$NITRO_RESP" == "200" ]]; then pass "NITRO API reachable (HTTP $NITRO_RESP)"
else fail "NITRO API reachable" "200" "$NITRO_RESP"; fi

# Version
VPX_VER=$(nitro "nsversion" | field "version")
[[ "$VPX_VER" != "NOT_FOUND" ]] && pass "VPX version: $VPX_VER" || warn "VPX version" "could not read"

# =========================================================================
# 2. FEATURES & MODES
# =========================================================================
section "2. Features & Modes"

for feat in lb cs ssl rewrite responder cmp; do
    check "Feature: $feat" "nsfeature" "$feat" "true"
done

for mode in fr tcpb edge l3 ulfd; do
    check "Mode: $mode" "nsmode" "$mode" "true"
done

# =========================================================================
# 3. SYSTEM PARAMETERS
# =========================================================================
section "3. System Parameters"

check "Strong password" "systemparameter" "strongpassword" "enableall"
check "Min password length" "systemparameter" "minpasswordlen" "8"
check "Session timeout" "systemparameter" "timeout" "900"
check "Max clients" "systemparameter" "maxclient" "10"
check "Restricted timeout" "systemparameter" "restrictedtimeout" "ENABLED"
check "Basic auth disabled" "systemparameter" "basicauth" "DISABLED"

# =========================================================================
# 4. HTTP & TCP PROFILES
# =========================================================================
section "4. HTTP & TCP Profiles"

check "HTTP profile exists" "nshttpprofile/nshttp_hardened"
check "HTTP drop invalid" "nshttpprofile/nshttp_hardened" "dropinvalreqs" "ENABLED"
check "HTTP mark 0.9 invalid" "nshttpprofile/nshttp_hardened" "markhttp09inval" "ENABLED"
check "HTTP mark CONNECT invalid" "nshttpprofile/nshttp_hardened" "markconnreqinval" "ENABLED"
check "HTTP mark TRACE invalid" "nshttpprofile/nshttp_hardened" "marktracereqinval" "ENABLED"
check "HTTP multiplexing" "nshttpprofile/nshttp_hardened" "conmultiplex" "ENABLED"
check "HTTP/2 enabled" "nshttpprofile/nshttp_hardened" "http2" "ENABLED"
check "HTTP/2 max streams" "nshttpprofile/nshttp_hardened" "http2maxconcurrentstreams" "128"

check "TCP profile exists" "nstcpprofile/nstcp_hardened"
check "TCP window scaling" "nstcpprofile/nstcp_hardened" "ws" "ENABLED"
check "TCP SACK" "nstcpprofile/nstcp_hardened" "sack" "ENABLED"
check "TCP Nagle disabled" "nstcpprofile/nstcp_hardened" "nagle" "DISABLED"
check "TCP ECN" "nstcpprofile/nstcp_hardened" "ecn" "ENABLED"
check "TCP DSACK" "nstcpprofile/nstcp_hardened" "dsack" "ENABLED"
check "TCP F-RTO" "nstcpprofile/nstcp_hardened" "frto" "ENABLED"
check "TCP SYN flood protection" "nstcpprofile/nstcp_hardened" "spoofsyndrop" "ENABLED"
check "TCP RST attenuation" "nstcpprofile/nstcp_hardened" "rstwindowattenuate" "ENABLED"
check "TCP initial CWND" "nstcpprofile/nstcp_hardened" "initialcwnd" "16"
check "TCP OOO queue size" "nstcpprofile/nstcp_hardened" "oooqsize" "300"
check "TCP keepalive" "nstcpprofile/nstcp_hardened" "ka" "ENABLED"
check "TCP keepalive idle" "nstcpprofile/nstcp_hardened" "kaconnidletime" "900"
check "TCP congestion: CUBIC" "nstcpprofile/nstcp_hardened" "flavor" "CUBIC"

# =========================================================================
# 5. TIMEOUTS
# =========================================================================
section "5. Timeouts"

check "Zombie timeout" "nstimeout" "zombie" "600"
check "Half-close timeout" "nstimeout" "halfclose" "300"
check "Non-TCP zombie" "nstimeout" "nontcpzombie" "300"

# =========================================================================
# 6. SNIP
# =========================================================================
section "6. Network (SNIP)"

check "SNIP exists" "nsip/10.254.11.10" "type" "SNIP"

# =========================================================================
# 7. SSL CERTIFICATES
# =========================================================================
section "7. SSL Certificates"

check "Lab CA cert" "sslcertkey/lab-ca"
check "Wildcard cert" "sslcertkey/wildcard"
check "Wildcard chain linked" "sslcertkey/wildcard" "linkcertkeyname" "lab-ca"

for f in lab-ca.crt wildcard.crt wildcard.key; do
    RESP=$(nitro "systemfile?args=filename:${f},filelocation:%2Fnsconfig%2Fssl")
    EC=$(echo "$RESP" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('errorcode',999))" 2>/dev/null || echo "999")
    [[ "$EC" == "0" ]] && pass "SSL file: $f" || fail "SSL file: $f" "exists" "ec=$EC"
done

# Cert expiry
DAYS=$(nitro "sslcertkey/wildcard" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        items=d[k] if isinstance(d[k],list) else [d[k]]
        print(items[0].get('daystoexpiration','UNKNOWN'))
        break
" 2>/dev/null || echo "UNKNOWN")
if [[ "$DAYS" =~ ^[0-9]+$ ]] && [[ "$DAYS" -ge 30 ]]; then pass "Wildcard cert: ${DAYS} days remaining"
elif [[ "$DAYS" =~ ^[0-9]+$ ]]; then fail "Wildcard cert expiry" ">=30 days" "${DAYS} days"
else warn "Wildcard cert expiry" "could not determine"; fi

# =========================================================================
# 8. BACKEND & SERVICE GROUPS
# =========================================================================
section "8. Backend (httpbin.org)"

check "Server: srv_httpbin" "server/srv_httpbin"
check "Service group: sg_backend" "servicegroup/sg_backend" "servicetype" "SSL"
check "Monitor: mon_https_health" "lbmonitor/mon_https_health" "type" "HTTP"
check "Monitor secure" "lbmonitor/mon_https_health" "secure" "YES"

# SG member binding
SG_BIND=$(nitro "servicegroup_servicegroupmember_binding/sg_backend")
SG_HAS=$(echo "$SG_BIND" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        items=d[k] if isinstance(d[k],list) else [d[k]]
        for i in items:
            if i.get('servername')=='srv_httpbin' and str(i.get('port'))=='443':
                print('yes'); sys.exit(0)
print('no')
" 2>/dev/null || echo "no")
[[ "$SG_HAS" == "yes" ]] && pass "sg_backend → srv_httpbin:443" || fail "sg_backend binding" "srv_httpbin:443" "not found"

# SG health
SG_STATE=$(nitro_stat "servicegroup/sg_backend" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        items=d[k] if isinstance(d[k],list) else [d[k]]
        for i in items:
            state=i.get('state','UNKNOWN')
            print(state); sys.exit(0)
print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")
[[ "$SG_STATE" == "UP" ]] && pass "sg_backend state: UP" || warn "sg_backend state" "$SG_STATE"

# =========================================================================
# 9. LB VSERVERS
# =========================================================================
section "9. LB vServers"

check "lb_vsrv_https exists" "lbvserver/lb_vsrv_https" "servicetype" "SSL"
check "lb_vsrv_https port" "lbvserver/lb_vsrv_https" "port" "443"
check "lb_vsrv_https method" "lbvserver/lb_vsrv_https" "lbmethod" "ROUNDROBIN"
check "lb_vsrv_https HTTP profile" "lbvserver/lb_vsrv_https" "httpprofilename" "nshttp_hardened"
check "lb_vsrv_https TCP profile" "lbvserver/lb_vsrv_https" "tcpprofilename" "nstcp_hardened"

check "lb_vsrv_http exists" "lbvserver/lb_vsrv_http" "servicetype" "HTTP"
check "lb_vsrv_http port" "lbvserver/lb_vsrv_http" "port" "80"

# VServer states
for vs in lb_vsrv_https lb_vsrv_http; do
    VS_STATE=$(nitro_stat "lbvserver/$vs" | field "state")
    [[ "$VS_STATE" == "UP" ]] && pass "$vs state: UP" || warn "$vs state" "$VS_STATE"
done

# =========================================================================
# 10. REWRITE & RESPONDER POLICIES
# =========================================================================
section "10. Rewrite & Responder Policies"

# Security header policies (response)
for pol in pol_hsts pol_xfo pol_xcto pol_xxss pol_referrer_policy pol_permissions_policy pol_csp pol_del_server pol_del_xpoweredby; do
    check "Rewrite: $pol" "rewritepolicy/$pol"
done

# Request enrichment policies
for pol in pol_xff pol_xrealip pol_xfproto pol_xrequestid; do
    check "Rewrite: $pol" "rewritepolicy/$pol"
done

# X-Request-ID echo
check "Rewrite: pol_rid_response" "rewritepolicy/pol_rid_response"

# Responder policies
check "Responder: pol_redirect_https" "responderpolicy/pol_redirect_https"
check "Responder: pol_block_bot" "responderpolicy/pol_block_bot"

# =========================================================================
# 11. BOT BLOCKING PATTERNS
# =========================================================================
section "11. Bot Blocking Patterns"

check "Patset: ps_bad_useragents" "policypatset/ps_bad_useragents"

for ua in sqlmap nikto nmap nuclei masscan dirbuster gobuster wpscan ZmEu; do
    FOUND=$(nitro "policypatset_pattern_binding/ps_bad_useragents" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        items=d[k] if isinstance(d[k],list) else [d[k]]
        for i in items:
            if i.get('String','').lower()=='$ua'.lower():
                print('yes'); sys.exit(0)
print('no')
" 2>/dev/null || echo "no")
    [[ "$FOUND" == "yes" ]] && pass "Bot pattern: $ua" || fail "Bot pattern: $ua" "bound" "not found"
done

# =========================================================================
# 12. SSL CIPHER BINDINGS
# =========================================================================
section "12. SSL Configuration"

CIPHER_DATA=$(nitro "sslvserver_sslciphersuite_binding/lb_vsrv_https")
for cipher in "TLS1.2-ECDHE-RSA-AES256-GCM-SHA384" "TLS1.2-ECDHE-RSA-AES128-GCM-SHA256" "TLS1.3-AES256-GCM-SHA384" "TLS1.3-AES128-GCM-SHA256"; do
    HAS=$(echo "$CIPHER_DATA" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        items=d[k] if isinstance(d[k],list) else [d[k]]
        for i in items:
            if i.get('ciphername','')=='$cipher':
                print('yes'); sys.exit(0)
print('no')
" 2>/dev/null || echo "no")
    [[ "$HAS" == "yes" ]] && pass "Cipher: $cipher" || fail "Cipher: $cipher" "bound" "not found"
done

# =========================================================================
# 13. VIP HEALTH CHECKS
# =========================================================================
section "13. VIP Health Checks"

# HTTPS endpoint
HTTP_CODE=$(curl -sk --connect-timeout 10 -o /dev/null -w "%{http_code}" "https://${VIP}/get" 2>/dev/null) || HTTP_CODE="000"
[[ "$HTTP_CODE" == "200" ]] && pass "VIP HTTPS /get → HTTP $HTTP_CODE" || fail "VIP HTTPS /get" "200" "$HTTP_CODE"

# httpbin.org response body validation
BODY=$(curl -sk --connect-timeout 10 "https://${VIP}/get" 2>/dev/null) || BODY=""
if echo "$BODY" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'headers' in d" 2>/dev/null; then
    pass "httpbin.org JSON response valid"
else
    fail "httpbin.org JSON response" "valid JSON with headers" "invalid"
fi

# X-Forwarded-For in httpbin response
XFF_PRESENT=$(echo "$BODY" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
h=d.get('headers',{})
print('yes' if 'X-Forwarded-For' in h or 'x-forwarded-for' in {k.lower():v for k,v in h.items()} else 'no')
" 2>/dev/null || echo "no")
[[ "$XFF_PRESENT" == "yes" ]] && pass "X-Forwarded-For injected into request" || warn "X-Forwarded-For" "not visible in httpbin response"

# X-Real-IP in httpbin response
XRIP_PRESENT=$(echo "$BODY" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
h=d.get('headers',{})
print('yes' if any(k.lower()=='x-real-ip' for k in h) else 'no')
" 2>/dev/null || echo "no")
[[ "$XRIP_PRESENT" == "yes" ]] && pass "X-Real-IP injected into request" || warn "X-Real-IP" "not visible in httpbin response"

# HTTP → HTTPS redirect
REDIR_CODE=$(curl -s --connect-timeout 10 -o /dev/null -w "%{http_code}" "http://${VIP}/" 2>/dev/null) || REDIR_CODE="000"
[[ "$REDIR_CODE" == "301" ]] && pass "HTTP→HTTPS redirect → HTTP $REDIR_CODE" || fail "HTTP→HTTPS redirect" "301" "$REDIR_CODE"

# =========================================================================
# 14. SECURITY HEADERS
# =========================================================================
section "14. Security Headers"

HEADERS=$(curl -sk -I --connect-timeout 10 "https://${VIP}/get" 2>/dev/null) || HEADERS=""

for hdr in "Strict-Transport-Security" "X-Frame-Options" "X-Content-Type-Options" "X-XSS-Protection" "Content-Security-Policy" "Referrer-Policy" "Permissions-Policy"; do
    VAL=$(echo "$HEADERS" | grep -i "^${hdr}:" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n' || true)
    if [[ -n "$VAL" ]]; then pass "Header: $hdr = $VAL"
    else fail "Header: $hdr" "present" "missing"; fi
done

# Verify sensitive headers removed
for hdr in "Server" "X-Powered-By"; do
    VAL=$(echo "$HEADERS" | grep -i "^${hdr}:" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n' || true)
    if [[ -z "$VAL" ]]; then pass "Removed: $hdr (not in response)"
    else fail "Removed: $hdr" "absent" "$VAL"; fi
done

# HSTS max-age check
HSTS_VAL=$(echo "$HEADERS" | grep -i "^Strict-Transport-Security:" | head -1 | tr -d '\r\n' || true)
if echo "$HSTS_VAL" | grep -q "max-age=31536000"; then pass "HSTS max-age=31536000"
else warn "HSTS max-age" "expected 31536000"; fi

# =========================================================================
# 15. SSL CERTIFICATE PROBING
# =========================================================================
section "15. SSL Certificate Probe"

CERT_RAW=$(echo | timeout 10 openssl s_client -connect "${VIP}:443" 2>/dev/null) || CERT_RAW=""
CERT_PEM=$(mktemp)
echo "$CERT_RAW" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > "$CERT_PEM"

if [[ -s "$CERT_PEM" ]]; then
    SUBJ=$(openssl x509 -in "$CERT_PEM" -noout -subject 2>/dev/null | sed 's/subject= *//')
    pass "Certificate subject: $SUBJ"

    ISSUER=$(openssl x509 -in "$CERT_PEM" -noout -issuer 2>/dev/null | sed 's/issuer= *//')
    pass "Certificate issuer: $ISSUER"

    EXPIRY=$(openssl x509 -in "$CERT_PEM" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    pass "Certificate expires: $EXPIRY"

    KEYSIZE=$(openssl x509 -in "$CERT_PEM" -noout -text 2>/dev/null | grep "Public-Key:" | head -1 | grep -oP '\d+' || true)
    if [[ "$KEYSIZE" =~ ^[0-9]+$ ]] && [[ "$KEYSIZE" -ge 2048 ]]; then pass "Key size: ${KEYSIZE} bit"
    else fail "Key size" ">=2048" "${KEYSIZE:-unknown}"; fi

    SIGALG=$(openssl x509 -in "$CERT_PEM" -noout -text 2>/dev/null | grep "Signature Algorithm" | head -1 | awk '{print $NF}' || true)
    pass "Signature algorithm: $SIGALG"
else
    fail "SSL certificate" "presented" "no cert received"
fi

# Protocol & cipher
PROTO=$(echo "$CERT_RAW" | grep -oP 'Protocol\s*:\s*\K\S+' | head -1 || true)
CIPHER=$(echo "$CERT_RAW" | grep -oP 'Cipher\s*:\s*\K\S+' | head -1 || true)

if [[ "$PROTO" =~ ^TLSv1\.[23]$ ]]; then pass "TLS protocol: $PROTO"
elif [[ -n "$PROTO" ]]; then fail "TLS protocol" "TLSv1.2+" "$PROTO"
else fail "TLS protocol" "detected" "could not determine"; fi

[[ -n "$CIPHER" && "$CIPHER" != "0000" ]] && pass "Cipher: $CIPHER" || warn "Cipher" "could not determine"

# Chain depth
DEPTH=$(echo "$CERT_RAW" | grep -c "^depth=" || echo "0")
[[ "$DEPTH" -ge 2 ]] && pass "Cert chain depth: $DEPTH" || warn "Cert chain" "depth=$DEPTH (expected >=2)"

rm -f "$CERT_PEM"

# =========================================================================
# 16. BOT BLOCKING (LIVE)
# =========================================================================
section "16. Bot Blocking (Live Requests)"

BOT_BLOCKED=0; BOT_TOTAL=0
for UA in "sqlmap/1.6" "nikto/2.1.6" "Nmap Scripting Engine" "nuclei/2.9.4" "masscan/1.3.2" \
          "DirBuster-1.0" "gobuster/3.5" "WPScan v3.8" "ZmEu"; do
    BOT_TOTAL=$((BOT_TOTAL+1))
    CODE=$(curl -sk --connect-timeout 10 -o /dev/null -w "%{http_code}" \
        -H "User-Agent: $UA" "https://${VIP}/get" 2>/dev/null) || CODE="000"
    if [[ "$CODE" == "403" ]]; then
        pass "Blocked: $UA → 403"
        BOT_BLOCKED=$((BOT_BLOCKED+1))
    else
        fail "Blocked: $UA" "403" "$CODE"
    fi
done

echo "  Bot blocking: ${BOT_BLOCKED}/${BOT_TOTAL} attack tools blocked"

# =========================================================================
# 17. PERFORMANCE METRICS — Single Request Breakdown
# =========================================================================
section "17. Performance Metrics (Single Request)"

PERF_FMT='dns=%{time_namelookup} tcp=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} size=%{size_download} speed=%{speed_download}'
PERF=$(curl -sk --connect-timeout 10 -o /dev/null -w "$PERF_FMT" "https://${VIP}/get" 2>/dev/null) || PERF=""

if [[ -n "$PERF" ]]; then
    # Parse values
    DNS_S=$(echo "$PERF" | grep -oP 'dns=\K[0-9.]+')
    TCP_S=$(echo "$PERF" | grep -oP 'tcp=\K[0-9.]+')
    TLS_S=$(echo "$PERF" | grep -oP 'tls=\K[0-9.]+')
    TTFB_S=$(echo "$PERF" | grep -oP 'ttfb=\K[0-9.]+')
    TOTAL_S=$(echo "$PERF" | grep -oP 'total=\K[0-9.]+')
    SIZE_B=$(echo "$PERF" | grep -oP 'size=\K[0-9.]+')
    SPEED=$(echo "$PERF" | grep -oP 'speed=\K[0-9.]+')

    # Convert to ms
    read -r DNS_MS TCP_MS TLS_MS TTFB_MS TOTAL_MS RTT_MS SPEED_KB <<< $(python3 -c "
dns=$DNS_S; tcp=$TCP_S; tls=$TLS_S; ttfb=$TTFB_S; total=$TOTAL_S; speed=$SPEED
print(f'{dns*1000:.1f} {tcp*1000:.1f} {(tls-tcp)*1000:.1f} {ttfb*1000:.1f} {total*1000:.1f} {tcp*2*1000:.1f} {speed/1024:.1f}')
")

    echo ""
    printf "  %-28s %s\n" "DNS Lookup:" "${DNS_MS}ms"
    printf "  %-28s %s\n" "TCP Connect:" "${TCP_MS}ms"
    printf "  %-28s %s\n" "TLS Handshake:" "${TLS_MS}ms"
    printf "  %-28s %s\n" "Time to First Byte (TTFB):" "${TTFB_MS}ms"
    printf "  %-28s %s\n" "Total Time:" "${TOTAL_MS}ms"
    printf "  %-28s %s\n" "Round-Trip Time (est):" "${RTT_MS}ms"
    printf "  %-28s %s\n" "Response Size:" "${SIZE_B} bytes"
    printf "  %-28s %s\n" "Transfer Speed:" "${SPEED_KB} KB/s"
    echo ""

    # Thresholds
    TCP_INT=${TCP_MS%.*}
    TLS_INT=${TLS_MS%.*}
    TTFB_INT=${TTFB_MS%.*}
    TOTAL_INT=${TOTAL_MS%.*}

    [[ "$TCP_INT" -lt 500 ]] && pass "TCP connect < 500ms (${TCP_MS}ms)" || warn "TCP connect" "${TCP_MS}ms (>500ms)"
    [[ "$TLS_INT" -lt 1000 ]] && pass "TLS handshake < 1s (${TLS_MS}ms)" || warn "TLS handshake" "${TLS_MS}ms (>1s)"
    [[ "$TTFB_INT" -lt 3000 ]] && pass "TTFB < 3s (${TTFB_MS}ms)" || warn "TTFB" "${TTFB_MS}ms (>3s)"
    [[ "$TOTAL_INT" -lt 5000 ]] && pass "Total < 5s (${TOTAL_MS}ms)" || warn "Total time" "${TOTAL_MS}ms (>5s)"
else
    fail "Performance metrics" "collected" "curl failed"
fi

# =========================================================================
# 18. PERFORMANCE — Multi-Request Timing (20 requests)
# =========================================================================
section "18. Performance Metrics (20 Requests)"

TIMING_TMP=$(mktemp)
for i in $(seq 1 20); do
    curl -sk --connect-timeout 10 -o /dev/null \
        -w "%{time_connect}\t%{time_appconnect}\t%{time_starttransfer}\t%{time_total}\n" \
        "https://${VIP}/get" 2>/dev/null >> "$TIMING_TMP" || true
done

REQ_COUNT=$(wc -l < "$TIMING_TMP")
if [[ "$REQ_COUNT" -gt 0 ]]; then
    STATS=$(python3 -c "
import sys
lines=open('$TIMING_TMP').readlines()
data=[]
for l in lines:
    parts=l.strip().split('\t')
    if len(parts)==4:
        tcp,tls,ttfb,total=[float(x)*1000 for x in parts]
        data.append({'tcp':tcp,'tls':tls-tcp,'ttfb':ttfb,'total':total})
if not data:
    print('NO_DATA'); sys.exit(0)
n=len(data)
for metric in ['tcp','tls','ttfb','total']:
    vals=sorted([d[metric] for d in data])
    avg=sum(vals)/n
    mn=vals[0]; mx=vals[-1]
    p50=vals[int(n*0.5)]; p95=vals[min(int(n*0.95),n-1)]; p99=vals[min(int(n*0.99),n-1)]
    print(f'{metric}\t{mn:.1f}\t{avg:.1f}\t{p50:.1f}\t{p95:.1f}\t{p99:.1f}\t{mx:.1f}')
")

    if [[ "$STATS" != "NO_DATA" ]]; then
        echo ""
        printf "  %-12s %8s %8s %8s %8s %8s %8s\n" "Metric" "Min" "Avg" "P50" "P95" "P99" "Max"
        printf "  %-12s %8s %8s %8s %8s %8s %8s\n" "────────" "──────" "──────" "──────" "──────" "──────" "──────"
        echo "$STATS" | while IFS=$'\t' read -r metric mn avg p50 p95 p99 mx; do
            label=$(echo "$metric" | tr '[:lower:]' '[:upper:]')
            printf "  %-12s %7sms %7sms %7sms %7sms %7sms %7sms\n" "$label" "$mn" "$avg" "$p50" "$p95" "$p99" "$mx"
        done
        echo "  ($REQ_COUNT requests)"
        echo ""

        # Check P95 TTFB
        P95_TTFB=$(echo "$STATS" | grep "^ttfb" | cut -f5)
        P95_INT=${P95_TTFB%.*}
        [[ "$P95_INT" -lt 5000 ]] && pass "P95 TTFB < 5s (${P95_TTFB}ms)" || warn "P95 TTFB" "${P95_TTFB}ms (>5s)"

        AVG_TOTAL=$(echo "$STATS" | grep "^total" | cut -f3)
        pass "Avg response time: ${AVG_TOTAL}ms (20 requests)"
    else
        warn "Multi-request timing" "no data collected"
    fi
else
    fail "Multi-request timing" "20 requests" "0 completed"
fi
rm -f "$TIMING_TMP"

# =========================================================================
# 19. STRESS TEST — Concurrent Requests
# =========================================================================
section "19. Stress Test — Concurrent (10 parallel × 5 rounds = 50 requests)"

STRESS_TMP=$(mktemp -d)
STRESS_FAIL=0
STRESS_OK=0
STRESS_START=$(date +%s%N)

for round in $(seq 1 5); do
    for i in $(seq 1 10); do
        (
            CODE=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w "%{http_code}" \
                "https://${VIP}/get" 2>/dev/null) || CODE="000"
            echo "$CODE" > "${STRESS_TMP}/r${round}_${i}"
        ) &
    done
    wait
done

STRESS_END=$(date +%s%N)
STRESS_ELAPSED=$(( (STRESS_END - STRESS_START) / 1000000 ))

for f in "${STRESS_TMP}"/r*; do
    CODE=$(cat "$f" 2>/dev/null || echo "000")
    [[ "$CODE" == "200" ]] && STRESS_OK=$((STRESS_OK+1)) || STRESS_FAIL=$((STRESS_FAIL+1))
done
STRESS_TOTAL=$((STRESS_OK + STRESS_FAIL))
RPS=$(python3 -c "print(f'{$STRESS_TOTAL / ($STRESS_ELAPSED/1000):.1f}')" 2>/dev/null || echo "0")

echo ""
printf "  %-28s %s\n" "Total Requests:" "$STRESS_TOTAL"
printf "  %-28s %s\n" "Successful (200):" "$STRESS_OK"
printf "  %-28s %s\n" "Failed:" "$STRESS_FAIL"
printf "  %-28s %s\n" "Elapsed:" "${STRESS_ELAPSED}ms"
printf "  %-28s %s\n" "Throughput:" "${RPS} req/s"
echo ""

SUCCESS_PCT=$((STRESS_OK * 100 / (STRESS_TOTAL > 0 ? STRESS_TOTAL : 1)))
[[ "$SUCCESS_PCT" -ge 95 ]] && pass "Concurrent: ${SUCCESS_PCT}% success (${STRESS_OK}/${STRESS_TOTAL})" \
    || fail "Concurrent success rate" ">=95%" "${SUCCESS_PCT}%"
[[ "$STRESS_FAIL" -eq 0 ]] && pass "Zero errors under concurrent load" \
    || warn "Concurrent errors" "$STRESS_FAIL failed requests"

rm -rf "$STRESS_TMP"

# =========================================================================
# 20. STRESS TEST — Sustained Burst (100 sequential requests)
# =========================================================================
section "20. Stress Test — Sustained Burst (100 sequential requests)"

BURST_TMP=$(mktemp)
BURST_OK=0; BURST_FAIL=0
BURST_START=$(date +%s%N)

for i in $(seq 1 100); do
    CODE=$(curl -sk --connect-timeout 5 --max-time 10 -o /dev/null \
        -w "%{http_code}\t%{time_total}\n" "https://${VIP}/get" 2>/dev/null) || CODE="000\t0"
    echo "$CODE" >> "$BURST_TMP"
    STATUS=$(echo "$CODE" | cut -f1)
    [[ "$STATUS" == "200" ]] && BURST_OK=$((BURST_OK+1)) || BURST_FAIL=$((BURST_FAIL+1))
done

BURST_END=$(date +%s%N)
BURST_ELAPSED=$(( (BURST_END - BURST_START) / 1000000 ))
BURST_TOTAL=$((BURST_OK + BURST_FAIL))
BURST_RPS=$(python3 -c "print(f'{$BURST_TOTAL / ($BURST_ELAPSED/1000):.1f}')" 2>/dev/null || echo "0")

# Timing stats from burst
BURST_STATS=$(python3 -c "
import sys
times=[]
for line in open('$BURST_TMP'):
    parts=line.strip().split('\t')
    if len(parts)==2:
        try: times.append(float(parts[1])*1000)
        except: pass
if times:
    times.sort()
    n=len(times)
    print(f'{min(times):.1f}\t{sum(times)/n:.1f}\t{times[int(n*0.5)]:.1f}\t{times[min(int(n*0.95),n-1)]:.1f}\t{max(times):.1f}')
else:
    print('NO_DATA')
" 2>/dev/null || echo "NO_DATA")

echo ""
printf "  %-28s %s\n" "Total Requests:" "$BURST_TOTAL"
printf "  %-28s %s\n" "Successful (200):" "$BURST_OK"
printf "  %-28s %s\n" "Failed:" "$BURST_FAIL"
printf "  %-28s %s\n" "Elapsed:" "${BURST_ELAPSED}ms"
printf "  %-28s %s\n" "Sequential Throughput:" "${BURST_RPS} req/s"

if [[ "$BURST_STATS" != "NO_DATA" ]]; then
    IFS=$'\t' read -r B_MIN B_AVG B_P50 B_P95 B_MAX <<< "$BURST_STATS"
    printf "  %-28s %s\n" "Min Response:" "${B_MIN}ms"
    printf "  %-28s %s\n" "Avg Response:" "${B_AVG}ms"
    printf "  %-28s %s\n" "P50 Response:" "${B_P50}ms"
    printf "  %-28s %s\n" "P95 Response:" "${B_P95}ms"
    printf "  %-28s %s\n" "Max Response:" "${B_MAX}ms"
fi
echo ""

BURST_PCT=$((BURST_OK * 100 / (BURST_TOTAL > 0 ? BURST_TOTAL : 1)))
[[ "$BURST_PCT" -ge 95 ]] && pass "Burst: ${BURST_PCT}% success (${BURST_OK}/${BURST_TOTAL})" \
    || fail "Burst success rate" ">=95%" "${BURST_PCT}%"

rm -f "$BURST_TMP"

# =========================================================================
# 21. STRESS TEST — Mixed Workload (concurrent GET/POST/HEAD)
# =========================================================================
section "21. Stress Test — Mixed Methods (30 parallel requests)"

MIXED_TMP=$(mktemp -d)
METHODS=("GET" "GET" "GET" "GET" "GET" "POST" "POST" "HEAD" "HEAD" "GET")

for i in $(seq 1 30); do
    METHOD=${METHODS[$((i % ${#METHODS[@]}))]}
    (
        CODE=$(curl -sk --connect-timeout 10 --max-time 15 -X "$METHOD" \
            -o /dev/null -w "%{http_code}" "https://${VIP}/get" 2>/dev/null) || CODE="000"
        echo "${METHOD}:${CODE}" > "${MIXED_TMP}/m_${i}"
    ) &
done
wait

MIXED_OK=0; MIXED_FAIL=0
declare -A METHOD_COUNTS
for f in "${MIXED_TMP}"/m_*; do
    ENTRY=$(cat "$f" 2>/dev/null || echo "GET:000")
    M=$(echo "$ENTRY" | cut -d: -f1)
    C=$(echo "$ENTRY" | cut -d: -f2)
    METHOD_COUNTS[$M]=$(( ${METHOD_COUNTS[$M]:-0} + 1 ))
    [[ "$C" =~ ^(200|405)$ ]] && MIXED_OK=$((MIXED_OK+1)) || MIXED_FAIL=$((MIXED_FAIL+1))
done

echo ""
for M in "${!METHOD_COUNTS[@]}"; do
    printf "  %-28s %s requests\n" "$M:" "${METHOD_COUNTS[$M]}"
done
printf "  %-28s %s\n" "Successful:" "$MIXED_OK"
printf "  %-28s %s\n" "Failed:" "$MIXED_FAIL"
echo ""

MIXED_TOTAL=$((MIXED_OK + MIXED_FAIL))
MIXED_PCT=$((MIXED_OK * 100 / (MIXED_TOTAL > 0 ? MIXED_TOTAL : 1)))
[[ "$MIXED_PCT" -ge 90 ]] && pass "Mixed methods: ${MIXED_PCT}% success" \
    || fail "Mixed methods" ">=90%" "${MIXED_PCT}%"

rm -rf "$MIXED_TMP"

# =========================================================================
# 22. VPX SYSTEM STATS
# =========================================================================
section "22. VPX System Statistics"

SYS_STATS=$(nitro_stat "ns")
if [[ -n "$SYS_STATS" ]]; then
    CPU=$(echo "$SYS_STATS" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        v=d[k] if isinstance(d[k],list) else [d[k]]
        if v:
            print(v[0].get('cpuusagepcnt','?'))
        break
" 2>/dev/null || echo "?")
    MEM=$(echo "$SYS_STATS" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        v=d[k] if isinstance(d[k],list) else [d[k]]
        if v:
            print(v[0].get('memusagepcnt','?'))
        break
" 2>/dev/null || echo "?")
    HTTP_REQ=$(echo "$SYS_STATS" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        v=d[k] if isinstance(d[k],list) else [d[k]]
        if v:
            print(v[0].get('httptotrequests','?'))
        break
" 2>/dev/null || echo "?")
    HTTP_RESP=$(echo "$SYS_STATS" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        v=d[k] if isinstance(d[k],list) else [d[k]]
        if v:
            print(v[0].get('httptotresponses','?'))
        break
" 2>/dev/null || echo "?")
    TCP_CUR=$(echo "$SYS_STATS" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for k in d:
    if k not in ('errorcode','message','severity'):
        v=d[k] if isinstance(d[k],list) else [d[k]]
        if v:
            print(v[0].get('tcpcurclientconn','?'))
        break
" 2>/dev/null || echo "?")

    echo ""
    printf "  %-28s %s%%\n" "CPU Usage:" "$CPU"
    printf "  %-28s %s%%\n" "Memory Usage:" "$MEM"
    printf "  %-28s %s\n" "Total HTTP Requests:" "$HTTP_REQ"
    printf "  %-28s %s\n" "Total HTTP Responses:" "$HTTP_RESP"
    printf "  %-28s %s\n" "Current TCP Connections:" "$TCP_CUR"
    echo ""
    pass "VPX system stats collected"
else
    warn "VPX system stats" "could not retrieve"
fi

# =========================================================================
# FINAL SUMMARY
# =========================================================================
echo ""
echo "==========================================================================="
echo "  TEST SUMMARY"
echo "==========================================================================="
echo ""
printf "  %-12s %d\n" "Total:" "$TOTAL"
printf "  %-12s %d\n" "Passed:" "$PASSED"
printf "  %-12s %d\n" "Failed:" "$FAILED"
printf "  %-12s %d\n" "Warnings:" "$WARNINGS"
echo ""
if [[ "$FAILED" -eq 0 ]]; then
    echo "  RESULT: ALL TESTS PASSED"
elif [[ "$FAILED" -le 5 ]]; then
    echo "  RESULT: MOSTLY PASSED ($FAILED failures)"
else
    echo "  RESULT: $FAILED FAILURES — review above"
fi
echo ""
echo "  VIP:     https://${VIP}/get"
echo "  Backend: httpbin.org"
echo "==========================================================================="
