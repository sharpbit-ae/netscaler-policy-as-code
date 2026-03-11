#!/usr/bin/env python3
"""Generate realistic sample data for VPX firmware regression report."""
import json
import os
import sys
import random
from datetime import datetime, timedelta, timezone

random.seed(42)
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/vpx-sample-report"

# ─── Test result helpers ───

def pass_test(cat, test, expected, detail=""):
    return {"category": cat, "test": test, "status": "PASS",
            "expected": str(expected), "actual": str(expected), "detail": detail}

def fail_test(cat, test, expected, actual, detail=""):
    return {"category": cat, "test": test, "status": "FAIL",
            "expected": str(expected), "actual": str(actual), "detail": detail}

def warn_test(cat, test, expected, actual, detail=""):
    return {"category": cat, "test": test, "status": "WARN",
            "expected": str(expected), "actual": str(actual), "detail": detail}

# ─── Build 375 test results per VPX ───

def build_results(is_candidate=False):
    r = []

    # 1. Features (8 tests)
    for feat in ["lb", "cs", "ssl", "rewrite", "responder", "cmp", "appflow", "ic"]:
        r.append(pass_test("Features", f"nsfeature.{feat}", "true"))

    # 2. Modes (5 tests)
    for mode in ["fr", "tcpb", "edge", "l3", "ulfd"]:
        r.append(pass_test("Modes", f"nsmode.{mode}", "true"))

    # 3. System Parameters (7 tests)
    for k, v in [("minpasswordlen", "8"), ("strongpassword", "enableall"),
                 ("maxclient", "10"), ("timeout", "900"),
                 ("restrictedtimeout", "enabled"), ("basicauth", "disabled"),
                 ("reauthonauthparamchange", "enabled")]:
        r.append(pass_test("System Parameters", f"systemparameter.{k}", v))

    # 4. Management (5 tests)
    for k, v in [("nsip.restrictaccess", "ENABLED"), ("nsip.gui", "SECUREONLY"),
                 ("nsip.mgmtaccess", "ENABLED"), ("nsip.type", "NSIP"),
                 ("nsrpcnode.secure", "ON")]:
        r.append(pass_test("Management", k, v))

    # 5. SSL Frontend Profile (9 tests)
    for k, v in [("ssl3", "DISABLED"), ("tls1", "DISABLED"), ("tls11", "DISABLED"),
                 ("tls12", "ENABLED"), ("tls13", "ENABLED"),
                 ("denysslreneg", "NONSECURE"), ("hsts", "ENABLED"),
                 ("maxage", "31536000"), ("sslprofile.name", "ns_default_ssl_profile_frontend")]:
        if is_candidate and k == "tls13":
            r.append(fail_test("SSL Frontend Profile", f"sslprofile_frontend.{k}",
                              "ENABLED", "DISABLED",
                              "REGRESSION: TLS 1.3 not enabled after firmware upgrade"))
        else:
            r.append(pass_test("SSL Frontend Profile", f"sslprofile_frontend.{k}", v))

    # 6. SSL Backend Profile (5 tests)
    for k, v in [("ssl3", "DISABLED"), ("tls1", "DISABLED"), ("tls11", "DISABLED"),
                 ("tls12", "ENABLED"), ("tls13", "ENABLED")]:
        r.append(pass_test("SSL Backend Profile", f"sslprofile_backend.{k}", v))

    # 7. SSL Ciphers (4 tests)
    for p, c in [(1, "TLS1.2-AES256-GCM-SHA384"), (2, "TLS1.2-AES128-GCM-SHA256"),
                 (3, "TLS1.3-AES256-GCM-SHA384"), (4, "TLS1.3-CHACHA20-POLY1305-SHA256")]:
        r.append(pass_test("SSL Ciphers", f"cipher_priority_{p}", c))

    # 8. Certificates (6 tests)
    for k, v in [("certkey.wildcard.lab.local", "wildcard.lab.local"),
                 ("certkey.wildcard.cert", "/nsconfig/ssl/wildcard.lab.local.crt"),
                 ("certkey.wildcard.key", "/nsconfig/ssl/wildcard.lab.local.key"),
                 ("certkey.lab-ca", "lab-ca"),
                 ("certkey.chain", "lab-ca"),
                 ("cert.wildcard.daystoexpiry", ">30")]:
        r.append(pass_test("Certificates", k, v))

    # 9. Service Groups (40 tests)
    for sg, stype in [("sg_web_http", "HTTP"), ("sg_web_https", "SSL"),
                       ("sg_tcp_generic", "TCP"), ("sg_dns", "DNS")]:
        r.append(pass_test("Service Groups", f"{sg}.servicetype", stype))
        r.append(pass_test("Service Groups", f"{sg}.usip", "NO"))
        r.append(pass_test("Service Groups", f"{sg}.cka", "YES"))
        r.append(pass_test("Service Groups", f"{sg}.tcpb", "YES"))
        # Members
        for srv in ["srv_host01", "srv_opnsense"]:
            r.append(pass_test("Service Groups", f"{sg}.member.{srv}", "present"))
            r.append(pass_test("Service Groups", f"{sg}.member.{srv}.state", "ENABLED"))
        # Monitor binding
        mon = {"sg_web_http": "mon_http_200", "sg_web_https": "mon_https_200",
               "sg_tcp_generic": "mon_tcp_quick", "sg_dns": "dns"}[sg]
        r.append(pass_test("Service Groups", f"{sg}.monitor", mon))
        r.append(pass_test("Service Groups", f"{sg}.monitor.state", "BOUND"))

    # 10. LB VServers (30 tests)
    for lb, stype, method, persist in [
        ("lb_vsrv_web", "HTTP", "ROUNDROBIN", "COOKIEINSERT"),
        ("lb_vsrv_api", "HTTP", "LEASTCONNECTION", "SOURCEIP"),
        ("lb_vsrv_web_ssl", "SSL", "ROUNDROBIN", "SOURCEIP"),
        ("lb_vsrv_tcp", "TCP", "LEASTCONNECTION", "SOURCEIP"),
        ("lb_vsrv_dns", "DNS", "ROUNDROBIN", "NONE"),
    ]:
        r.append(pass_test("LB VServers", f"{lb}.servicetype", stype))
        r.append(pass_test("LB VServers", f"{lb}.lbmethod", method))
        r.append(pass_test("LB VServers", f"{lb}.persistencetype", persist))
        r.append(pass_test("LB VServers", f"{lb}.curstate", "UP"))
        r.append(pass_test("LB VServers", f"{lb}.effectivestate", "UP"))
        r.append(pass_test("LB VServers", f"{lb}.tcpprofilename", "tcp_prof_web"))

    # 11. CS VServers (16 tests)
    for cs, stype, port in [("cs_vsrv_https", "SSL", "443"), ("cs_vsrv_http", "HTTP", "80")]:
        r.append(pass_test("CS VServers", f"{cs}.servicetype", stype))
        r.append(pass_test("CS VServers", f"{cs}.port", port))
        r.append(pass_test("CS VServers", f"{cs}.curstate", "UP"))
        r.append(pass_test("CS VServers", f"{cs}.tcpprofilename", "tcp_prof_web"))
        r.append(pass_test("CS VServers", f"{cs}.httpprofilename", "http_prof_web"))
    # CS policies
    for pol, rule_frag in [("cs_pol_api", "api.lab.local"), ("cs_pol_static", "static.lab.local"),
                            ("cs_pol_app", "app.lab.local")]:
        r.append(pass_test("CS VServers", f"{pol}.bound_to_cs_vsrv_https", "true"))
        r.append(pass_test("CS VServers", f"{pol}.rule_contains", rule_frag))

    # 12. Rewrite Policies (50 tests — actions + policies + bindings)
    # Security headers (response)
    security_headers = [
        ("rw_act_xframe", "insert_http_header", "X-Frame-Options"),
        ("rw_act_nosniff", "insert_http_header", "X-Content-Type-Options"),
        ("rw_act_xss", "insert_http_header", "X-XSS-Protection"),
        ("rw_act_referrer", "insert_http_header", "Referrer-Policy"),
        ("rw_act_permissions", "insert_http_header", "Permissions-Policy"),
        ("rw_act_csp", "insert_http_header", "Content-Security-Policy"),
        ("rw_act_del_server", "delete_http_header", "Server"),
        ("rw_act_del_powered", "delete_http_header", "X-Powered-By"),
        ("rw_act_del_aspnet", "delete_http_header", "X-AspNet-Version"),
        ("rw_act_download_options", "insert_http_header", "X-Download-Options"),
        ("rw_act_cross_domain", "insert_http_header", "X-Permitted-Cross-Domain-Policies"),
        ("rw_act_cache_control", "insert_http_header", "Cache-Control"),
    ]
    for act, atype, target in security_headers:
        r.append(pass_test("Rewrite Policies", f"{act}.type", atype))
        r.append(pass_test("Rewrite Policies", f"{act}.target", target))

    # Request headers
    for act, target in [("rw_act_xff", "X-Forwarded-For"), ("rw_act_xrealip", "X-Real-IP"),
                         ("rw_act_xproto", "X-Forwarded-Proto"), ("rw_act_reqid", "X-Request-ID")]:
        r.append(pass_test("Rewrite Policies", f"{act}.type", "insert_http_header"))
        r.append(pass_test("Rewrite Policies", f"{act}.target", target))

    # CORS
    for h in ["cors_origin", "cors_methods", "cors_headers", "cors_credentials", "cors_maxage"]:
        r.append(pass_test("Rewrite Policies", f"rw_act_{h}.type", "insert_http_header"))
        r.append(pass_test("Rewrite Policies", f"rw_pol_{h}.bound", "cs_vsrv_https:RESPONSE"))

    # Audit noop
    r.append(pass_test("Rewrite Policies", "rw_act_log_req.type", "noop"))
    r.append(pass_test("Rewrite Policies", "rw_act_log_res.type", "noop"))
    r.append(pass_test("Rewrite Policies", "rw_pol_log_req.logaction", "audit_act_request"))
    r.append(pass_test("Rewrite Policies", "rw_pol_log_res.logaction", "audit_act_response"))

    # 13. Responder Policies (12 tests)
    r.append(pass_test("Responder Policies", "rs_act_https_redirect.type", "redirect"))
    r.append(pass_test("Responder Policies", "rs_act_https_redirect.responsestatuscode", "301"))
    r.append(pass_test("Responder Policies", "rs_pol_https_redirect.bound", "cs_vsrv_http:REQUEST"))
    r.append(pass_test("Responder Policies", "rs_act_cors_preflight.type", "respondwith"))
    r.append(pass_test("Responder Policies", "rs_pol_cors_preflight.bound", "cs_vsrv_https:REQUEST"))
    r.append(pass_test("Responder Policies", "rs_pol_cors_preflight.priority", "25"))
    r.append(pass_test("Responder Policies", "rs_act_block_bot.type", "respondwith"))
    r.append(pass_test("Responder Policies", "rs_pol_block_bot.bound", "cs_vsrv_https:REQUEST"))
    r.append(pass_test("Responder Policies", "rs_pol_block_bot.priority", "40"))
    r.append(pass_test("Responder Policies", "rs_act_maintenance.type", "respondwith"))
    r.append(pass_test("Responder Policies", "rs_pol_maint1.bound", "cs_vsrv_https:REQUEST"))
    r.append(pass_test("Responder Policies", "rs_pol_maint1.priority", "30"))

    # 14. HTTP Profile (14 tests)
    for k, v in [("name", "http_prof_web"), ("dropinvalreqs", "ENABLED"),
                 ("markhttp09inval", "ENABLED"), ("markconnreqinval", "ENABLED"),
                 ("marktracereqinval", "ENABLED"), ("markrfc7230noncompliantinval", "ENABLED"),
                 ("conmultiplex", "ENABLED"), ("dropextradata", "ENABLED"),
                 ("websocket", "ENABLED"), ("http2", "ENABLED"),
                 ("http2maxconcurrentstreams", "128"), ("http2maxheaderlistsize", "32768"),
                 ("maxreusepool", "0")]:
        if is_candidate and k == "http2maxconcurrentstreams":
            r.append(fail_test("HTTP Profile", f"http_prof_web.{k}",
                              "128", "100",
                              "REGRESSION: HTTP/2 max concurrent streams reduced from 128 to 100"))
        else:
            r.append(pass_test("HTTP Profile", f"http_prof_web.{k}", v))
    r.append(pass_test("HTTP Profile", "http_prof_web.bound_to_cs_vsrv_https", "true"))

    # 15. TCP Profile (18 tests)
    for k, v in [("name", "tcp_prof_web"), ("ws", "ENABLED"), ("wsval", "8"),
                 ("sack", "ENABLED"), ("nagle", "DISABLED"), ("maxburst", "10"),
                 ("initialcwnd", "16"), ("oooqsize", "300"), ("minrto", "400"),
                 ("flavor", "CUBIC"), ("rstwindowattenuate", "ENABLED"),
                 ("spoofsyndrop", "ENABLED"), ("ecn", "ENABLED"),
                 ("timestamp", "ENABLED"), ("dsack", "ENABLED"), ("frto", "ENABLED"),
                 ("ka", "ENABLED"), ("kaconnidletime", "300")]:
        r.append(pass_test("TCP Profile", f"tcp_prof_web.{k}", v))

    # 16. Timeouts (3 tests)
    for k, v in [("zombie", "600"), ("halfclose", "300"), ("nontcpzombie", "300")]:
        r.append(pass_test("Timeouts", f"nstimeout.{k}", v))

    # 17. Compression Policies (10 tests)
    for pol, content_type in [("cmp_pol_text", "text/"), ("cmp_pol_json", "application/json"),
                               ("cmp_pol_js", "application/javascript"),
                               ("cmp_pol_xml", "application/xml"), ("cmp_pol_svg", "image/svg+xml")]:
        r.append(pass_test("Compression", f"{pol}.resaction", "COMPRESS"))
        r.append(pass_test("Compression", f"{pol}.bound", "cs_vsrv_https:RESPONSE"))

    # 18. Bot Blocking (12 tests)
    r.append(pass_test("Bot Blocking", "ps_bad_useragents.exists", "true"))
    for ua in ["sqlmap", "nikto", "masscan", "nmap", "dirbuster",
               "gobuster", "wpscan", "nuclei", "ZmEu", "python-requests"]:
        r.append(pass_test("Bot Blocking", f"ps_bad_useragents.contains.{ua}", "true"))
    if is_candidate:
        r.append(warn_test("Bot Blocking", "ps_bad_useragents.count", "10", "10",
                           "Consider adding 'curl/' and 'wget/' to bot blocking patset"))
    else:
        r.append(pass_test("Bot Blocking", "ps_bad_useragents.count", "10"))

    # 19. AppExpert Objects (8 tests)
    r.append(pass_test("AppExpert", "sm_url_routes.exists", "true"))
    for key, val in [("/api", "lb_vsrv_api"), ("/app", "lb_vsrv_web"), ("/health", "lb_vsrv_web")]:
        r.append(pass_test("AppExpert", f"sm_url_routes[{key}]", val))
    r.append(pass_test("AppExpert", "ps_allowed_origins.exists", "true"))
    for origin in ["https://app.lab.local", "https://api.lab.local", "https://lab.local"]:
        r.append(pass_test("AppExpert", f"ps_allowed_origins.contains.{origin.split('//')[1]}", "true"))

    # 20. Maintenance Mode (5 tests)
    r.append(pass_test("Maintenance Mode", "v_maintenance.type", "ulong"))
    r.append(pass_test("Maintenance Mode", "v_maintenance.scope", "global"))
    r.append(pass_test("Maintenance Mode", "a_maintenance_off.value", "0"))
    r.append(pass_test("Maintenance Mode", "a_maintenance_on.value", "1"))
    r.append(pass_test("Maintenance Mode", "rs_pol_maint1.rule", "$v_maintenance.EQ(1)"))

    # 21. Monitors (15 tests)
    for mon, mtype in [("mon_http_200", "HTTP"), ("mon_tcp_quick", "TCP"), ("mon_https_200", "HTTP-ECV")]:
        r.append(pass_test("Monitors", f"{mon}.type", mtype))
        r.append(pass_test("Monitors", f"{mon}.state", "ENABLED"))
        r.append(pass_test("Monitors", f"{mon}.retries", "3"))
    r.append(pass_test("Monitors", "mon_http_200.respcode", "200"))
    r.append(pass_test("Monitors", "mon_http_200.httprequest", "HEAD /"))
    r.append(pass_test("Monitors", "mon_http_200.interval", "10"))
    r.append(pass_test("Monitors", "mon_tcp_quick.interval", "5"))
    r.append(pass_test("Monitors", "mon_https_200.secure", "YES"))
    r.append(pass_test("Monitors", "mon_https_200.recv", "200 OK"))

    # 22. Servers (4 tests)
    r.append(pass_test("Servers", "srv_host01.ipaddress", "10.0.1.1"))
    r.append(pass_test("Servers", "srv_host01.state", "ENABLED"))
    r.append(pass_test("Servers", "srv_opnsense.ipaddress", "10.0.1.2"))
    r.append(pass_test("Servers", "srv_opnsense.state", "ENABLED"))

    # 23. SNIP (3 tests)
    snip = "10.0.1.254" if not is_candidate else "10.0.1.253"
    r.append(pass_test("SNIP", "nsip_snip.type", "SNIP"))
    r.append(pass_test("SNIP", "nsip_snip.mgmtaccess", "ENABLED"))
    r.append(pass_test("SNIP", "nsip_snip.ipaddress", snip))

    # 24. HTTP Probe - Live Response Testing (9 tests)
    b_connect = 12 if not is_candidate else 14
    b_tls = 45 if not is_candidate else 52
    b_ttfb = 89 if not is_candidate else 156
    b_total = 95 if not is_candidate else 178

    r.append({"category": "HTTPProbe", "test": "https_response_status", "status": "PASS",
              "expected": "valid HTTP response", "actual": "HTTP 200", "detail": ""})
    r.append({"category": "HTTPProbe", "test": "tcp_connect_time", "status": "PASS",
              "expected": "<1000ms", "actual": f"{b_connect}ms", "detail": "TCP connection established"})
    r.append({"category": "HTTPProbe", "test": "tls_handshake_time", "status": "PASS",
              "expected": "<2000ms", "actual": f"{b_tls}ms", "detail": "TLS negotiation completed"})
    if is_candidate:
        r.append({"category": "HTTPProbe", "test": "time_to_first_byte", "status": "WARN",
                  "expected": "<5000ms", "actual": f"{b_ttfb}ms",
                  "detail": "TTFB 75% slower than baseline (156ms vs 89ms)"})
    else:
        r.append({"category": "HTTPProbe", "test": "time_to_first_byte", "status": "PASS",
                  "expected": "<5000ms", "actual": f"{b_ttfb}ms", "detail": "Time to first byte"})
    r.append({"category": "HTTPProbe", "test": "total_response_time", "status": "PASS",
              "expected": "<10000ms", "actual": f"{b_total}ms", "detail": "Total request-response cycle"})
    r.append({"category": "HTTPProbe", "test": "timing_breakdown", "status": "PASS",
              "expected": "recorded",
              "actual": f"dns=0.001s tcp={b_connect/1000:.3f}s tls={b_tls/1000:.3f}s ttfb={b_ttfb/1000:.3f}s total={b_total/1000:.3f}s",
              "detail": f"Connect={b_connect}ms TLS={b_tls}ms TTFB={b_ttfb}ms Total={b_total}ms"})
    r.append(pass_test("HTTPProbe", "http_to_https_redirect", "301", "HTTP→HTTPS redirect working"))
    r.append({"category": "HTTPProbe", "test": "bot_blocking_active", "status": "PASS",
              "expected": "blocked", "actual": "HTTP 403", "detail": "Bot user-agent correctly blocked"})

    # 25. Response Header Validation (13 tests)
    security_headers = {
        "X-Frame-Options": "DENY",
        "X-Content-Type-Options": "nosniff",
        "X-XSS-Protection": "1; mode=block",
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Content-Security-Policy": "default-src 'self'",
        "Permissions-Policy": "geolocation=(), camera=(), microphone=()",
    }
    for hdr, val in security_headers.items():
        if is_candidate and hdr == "Strict-Transport-Security":
            r.append(fail_test("HeaderValidation", f"response_header:{hdr}", "present", "missing",
                              "REGRESSION: HSTS header not present in candidate response"))
        else:
            r.append({"category": "HeaderValidation", "test": f"response_header:{hdr}", "status": "PASS",
                      "expected": "present", "actual": val, "detail": ""})

    for hdr in ["Server", "X-Powered-By", "X-AspNet-Version"]:
        r.append(pass_test("HeaderValidation", f"removed_header:{hdr}", "absent"))

    if is_candidate:
        r.append(fail_test("HeaderValidation", "hsts_max_age", "max-age=31536000", "missing",
                          "HSTS header not found"))
    else:
        r.append({"category": "HeaderValidation", "test": "hsts_max_age", "status": "PASS",
                  "expected": "max-age=31536000", "actual": "max-age=31536000; includeSubDomains", "detail": ""})

    r.append({"category": "HeaderValidation", "test": "response_headers_collected", "status": "PASS",
              "expected": "collected", "actual": "14 headers", "detail": "All response headers captured for analysis"})

    # 26. SSL Certificate Probing (11 tests)
    r.append({"category": "SSLProbe", "test": "cert_subject", "status": "PASS",
              "expected": "contains lab.local", "actual": "CN = *.lab.local", "detail": ""})
    r.append({"category": "SSLProbe", "test": "cert_issuer", "status": "PASS",
              "expected": "Lab CA", "actual": "CN = Lab CA, O = Lab, C = US", "detail": ""})
    r.append({"category": "SSLProbe", "test": "cert_not_after", "status": "PASS",
              "expected": "valid", "actual": "Jun 10 00:00:00 2026 GMT", "detail": ""})
    r.append({"category": "SSLProbe", "test": "cert_not_before", "status": "PASS",
              "expected": "valid", "actual": "Mar 10 00:00:00 2026 GMT", "detail": ""})
    r.append({"category": "SSLProbe", "test": "cert_serial", "status": "PASS",
              "expected": "present", "actual": "7A3B4C5D6E7F8A9B", "detail": ""})
    r.append({"category": "SSLProbe", "test": "cert_signature_alg", "status": "PASS",
              "expected": "sha256+", "actual": "sha256WithRSAEncryption", "detail": ""})
    r.append({"category": "SSLProbe", "test": "cert_key_size", "status": "PASS",
              "expected": ">=2048 bit", "actual": "2048 bit", "detail": ""})
    r.append({"category": "SSLProbe", "test": "negotiated_protocol", "status": "PASS",
              "expected": "TLSv1.2 or TLSv1.3",
              "actual": "TLSv1.3" if not is_candidate else "TLSv1.2", "detail": ""})
    r.append({"category": "SSLProbe", "test": "negotiated_cipher", "status": "PASS",
              "expected": "AEAD cipher",
              "actual": "TLS_AES_256_GCM_SHA384" if not is_candidate else "ECDHE-RSA-AES256-GCM-SHA384",
              "detail": ""})
    r.append({"category": "SSLProbe", "test": "cert_chain_depth", "status": "PASS",
              "expected": ">=2 certificates", "actual": "2 certificates", "detail": "Full chain presented"})

    # Add candidate-only failure: SSL cert binding missing after upgrade
    if is_candidate:
        # Replace the passing cert binding test with a failure
        for i, t in enumerate(r):
            if t["test"] == "certkey.chain" and t["status"] == "PASS":
                r[i] = fail_test("Certificates", "certkey.chain", "lab-ca", "NONE",
                                "REGRESSION: Certificate chain link lost after firmware upgrade — wildcard cert no longer linked to CA")
                break

    return r


def build_json(nsip, hostname, results):
    passed = sum(1 for t in results if t["status"] == "PASS")
    failed = sum(1 for t in results if t["status"] == "FAIL")
    warnings = sum(1 for t in results if t["status"] == "WARN")
    return {
        "nsip": nsip,
        "hostname": hostname,
        "firmware": "NS14.1" if "baseline" in hostname else "NS14.1",
        "build": "Build 60.57" if "baseline" in hostname else "Build 65.12",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "warnings": warnings,
        "results": results,
    }


# ─── Generate CLI diffs ───

def generate_diffs():
    diffs = {}

    # Expected diff: version/build
    diffs["show version"] = """--- baseline/show_version.txt
+++ candidate/show_version.txt
@@ -1,3 +1,3 @@
 NetScaler NS14.1:
-  Build 60.57.nc
+  Build 65.12.nc
   Release date: Mar 01 2026"""

    # Expected diff: hardware serial (different VMs)
    diffs["show hardware"] = """--- baseline/show_hardware.txt
+++ candidate/show_hardware.txt
@@ -2,3 +2,3 @@
  Machine ID:    PLACEHOLDER_ID
- Serial Number: 7CDE8A3B1F02
+ Serial Number: 9ABF4C7D2E18
  Encoded serial: ..."""

    # UNEXPECTED diff: SSL default profile setting regression
    diffs["show ssl parameter"] = """--- baseline/show_ssl_parameter.txt
+++ candidate/show_ssl_parameter.txt
@@ -4,7 +4,7 @@
  SSL quantum size: 8 kBytes
  Max memory usage (MB): 0
  Session tickets: DISABLED
- Default Profile: ENABLED
+ Default Profile: ENABLED
  SSL Interception Max Reuse Sessions: 10
- Undefaction: CLIENTAUTH
+ Undefaction: RESET
  FIPS 140-2 Compliance: NO"""

    # UNEXPECTED diff: HTTP/2 max streams reset
    diffs["show httpprofile http_prof_web"] = """--- baseline/show_httpprofile.txt
+++ candidate/show_httpprofile.txt
@@ -8,7 +8,7 @@
  Connection multiplexing: ENABLED
  WebSocket: ENABLED
  HTTP/2: ENABLED
- HTTP/2 Max Concurrent Streams: 128
+ HTTP/2 Max Concurrent Streams: 100
  HTTP/2 Max Header List Size: 32768
  Drop invalid requests: ENABLED"""

    return diffs


# ─── Generate metrics CSV ───

def generate_metrics():
    """Simulate ~25 minutes of pipeline execution metrics at 10s intervals."""
    rows = []
    start = datetime(2026, 3, 10, 14, 0, 0, tzinfo=timezone.utc)

    for i in range(150):  # 150 samples = 25 minutes
        ts = start + timedelta(seconds=i * 10)
        t = i / 150  # normalized time 0-1

        # CPU: spikes during TF apply (t=0.2-0.4, t=0.5-0.7), low during waits
        if 0.05 < t < 0.15:    # KVM provision
            cpu = random.uniform(35, 55)
        elif 0.2 < t < 0.4:    # TF apply baseline
            cpu = random.uniform(40, 72)
        elif 0.5 < t < 0.7:    # TF apply candidate
            cpu = random.uniform(38, 68)
        elif 0.75 < t < 0.9:   # Tests running
            cpu = random.uniform(15, 35)
        else:
            cpu = random.uniform(5, 15)

        # Memory: gradual climb during deploy, steady during tests
        mem_base = 42 + t * 18
        mem = mem_base + random.uniform(-2, 3)

        # Network: bursts during provisioning and tests
        if 0.05 < t < 0.15 or 0.2 < t < 0.4 or 0.5 < t < 0.7:
            rx = random.uniform(5, 25)
            tx = random.uniform(2, 12)
        elif 0.75 < t < 0.9:
            rx = random.uniform(3, 15)
            tx = random.uniform(1, 8)
        else:
            rx = random.uniform(0.1, 2)
            tx = random.uniform(0.1, 1)

        # Disk: step up after QCOW2 copies
        disk = 45 + (8 if t > 0.1 else 0) + (8 if t > 0.5 else 0) + random.uniform(-0.5, 0.5)

        rows.append({
            "timestamp": ts.isoformat(),
            "cpu_pct": f"{cpu:.1f}",
            "mem_pct": f"{mem:.1f}",
            "net_rx_mbps": f"{rx:.2f}",
            "net_tx_mbps": f"{tx:.2f}",
            "disk_pct": f"{disk:.1f}",
        })

    return rows


# ─── Generate system logs ───

def generate_logs():
    logs = {}

    logs[("baseline", "nsconfig_audit.txt")] = """2026-03-10 14:05:12  CLI CMD_EXECUTED: set system parameter -minPasswdLen 8
2026-03-10 14:05:12  CLI CMD_EXECUTED: set system parameter -strongpassword enableall
2026-03-10 14:05:13  CLI CMD_EXECUTED: enable ns feature LB CS SSL REWRITE RESPONDER CMP AppFlow IC
2026-03-10 14:05:14  CLI CMD_EXECUTED: enable ns mode FR TCPB Edge L3 ULFD
2026-03-10 14:05:15  CLI CMD_EXECUTED: set ssl parameter -defaultProfile ENABLED
2026-03-10 14:06:22  WARM REBOOT initiated by nsroot from 10.0.1.1
2026-03-10 14:08:45  System started after warm reboot
2026-03-10 14:09:01  CLI CMD_EXECUTED: add ssl profile ns_default_ssl_profile_frontend
2026-03-10 14:09:02  CLI CMD_EXECUTED: bind ssl profile ns_default_ssl_profile_frontend -cipherName TLS1.2-AES256-GCM-SHA384
2026-03-10 14:09:15  CLI CMD_EXECUTED: add cs vserver cs_vsrv_https SSL 10.0.1.105 443
2026-03-10 14:09:16  CLI CMD_EXECUTED: add cs vserver cs_vsrv_http HTTP 10.0.1.105 80
2026-03-10 14:09:30  CLI CMD_EXECUTED: save ns config"""

    logs[("candidate", "nsconfig_audit.txt")] = """2026-03-10 14:12:33  CLI CMD_EXECUTED: set system parameter -minPasswdLen 8
2026-03-10 14:12:33  CLI CMD_EXECUTED: set system parameter -strongpassword enableall
2026-03-10 14:12:34  CLI CMD_EXECUTED: enable ns feature LB CS SSL REWRITE RESPONDER CMP AppFlow IC
2026-03-10 14:12:35  CLI CMD_EXECUTED: enable ns mode FR TCPB Edge L3 ULFD
2026-03-10 14:12:36  CLI CMD_EXECUTED: set ssl parameter -defaultProfile ENABLED
2026-03-10 14:13:45  WARM REBOOT initiated by nsroot from 10.0.1.1
2026-03-10 14:16:10  System started after warm reboot
2026-03-10 14:16:25  CLI CMD_EXECUTED: add ssl profile ns_default_ssl_profile_frontend
2026-03-10 14:16:26  WARNING: TLS 1.3 configuration may require additional cipher bindings
2026-03-10 14:16:27  CLI CMD_EXECUTED: bind ssl profile ns_default_ssl_profile_frontend -cipherName TLS1.2-AES256-GCM-SHA384
2026-03-10 14:16:40  CLI CMD_EXECUTED: add cs vserver cs_vsrv_https SSL 10.0.1.106 443
2026-03-10 14:16:41  CLI CMD_EXECUTED: add cs vserver cs_vsrv_http HTTP 10.0.1.106 80
2026-03-10 14:16:55  CLI CMD_EXECUTED: save ns config"""

    logs[("baseline", "ns_log.txt")] = """Mar 10 14:04:55 vpx-baseline kernel: FreeBSD 12.4-RELEASE amd64
Mar 10 14:05:00 vpx-baseline nsconfigd: Configuration daemon started
Mar 10 14:05:12 vpx-baseline nsapimgr: REST API session opened from 10.0.1.1
Mar 10 14:06:22 vpx-baseline nsconfigd: Warm reboot initiated
Mar 10 14:08:45 vpx-baseline kernel: System resumed after warm reboot
Mar 10 14:09:01 vpx-baseline nsconfigd: SSL default profile activated
Mar 10 14:09:30 vpx-baseline nsconfigd: Configuration saved to /nsconfig/ns.conf
Mar 10 14:20:01 vpx-baseline nsapimgr: NITRO API health check from 10.0.1.1 — 200 OK"""

    logs[("candidate", "ns_log.txt")] = """Mar 10 14:11:55 vpx-candidate kernel: FreeBSD 12.4-RELEASE amd64
Mar 10 14:12:00 vpx-candidate nsconfigd: Configuration daemon started
Mar 10 14:12:33 vpx-candidate nsapimgr: REST API session opened from 10.0.1.1
Mar 10 14:13:45 vpx-candidate nsconfigd: Warm reboot initiated
Mar 10 14:16:10 vpx-candidate kernel: System resumed after warm reboot
Mar 10 14:16:25 vpx-candidate nsconfigd: SSL default profile activated
Mar 10 14:16:26 vpx-candidate nsconfigd: WARNING — http2maxconcurrentstreams reset to firmware default (100)
Mar 10 14:16:55 vpx-candidate nsconfigd: Configuration saved to /nsconfig/ns.conf
Mar 10 14:22:01 vpx-candidate nsapimgr: NITRO API health check from 10.0.1.1 — 200 OK"""

    return logs


# ─── Generate probe timing CSV (50 requests) ───

def generate_probe_timings(is_candidate=False):
    """Generate 50 HTTP probe timing records for the bar chart."""
    rows = []
    scenarios = []

    # 1-10: Normal browsing
    for _ in range(10):
        scenarios.append(("normal", "app.lab.local", "GET", "Mozilla/5.0 Chrome/122.0", "https"))
    # 11-15: API
    for _ in range(5):
        scenarios.append(("api", "api.lab.local", "GET", "Mozilla/5.0 Chrome/122.0", "https"))
    # 16-20: Static
    for _ in range(5):
        scenarios.append(("static", "static.lab.local", "GET", "Mozilla/5.0 Chrome/122.0", "https"))
    # 21-25: Redirect
    for _ in range(5):
        scenarios.append(("redirect", "app.lab.local", "GET", "Mozilla/5.0 Chrome/122.0", "http"))
    # 26-35: Bot (blocked)
    for ua in ["sqlmap/1.6", "nikto/2.1.6", "Nmap Scripting Engine", "nuclei/2.9.4",
               "masscan/1.3.2", "DirBuster-1.0", "gobuster/3.5",
               "python-requests/2.31.0", "ZmEu", "WPScan v3.8"]:
        scenarios.append(("bot", "app.lab.local", "GET", ua, "https"))
    # 36-38: CORS
    for _ in range(3):
        scenarios.append(("cors", "app.lab.local", "OPTIONS", "Mozilla/5.0 Chrome/122.0", "https"))
    # 39-42: Methods
    for m in ["POST", "PUT", "DELETE", "PATCH"]:
        scenarios.append(("method", "app.lab.local", m, "Mozilla/5.0 Chrome/122.0", "https"))
    # 43-50: Burst
    for _ in range(8):
        scenarios.append(("burst", "app.lab.local", "GET", "Mozilla/5.0 Chrome/122.0", "https"))

    # Sample response headers by scenario type
    def sample_headers(scenario, status_code):
        base = [f"HTTP/1.1 {status_code}"]
        if scenario == "bot":
            return base + [
                "X-Frame-Options: DENY",
                "X-Content-Type-Options: nosniff",
                "Content-Length: 0",
                "Connection: close",
            ]
        if scenario == "redirect":
            return base + [
                "Location: https://app.lab.local/",
                "Content-Length: 0",
                "Connection: keep-alive",
            ]
        if scenario == "cors":
            return base + [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET; POST; OPTIONS",
                "Access-Control-Allow-Headers: Content-Type; Authorization",
                "Access-Control-Max-Age: 86400",
                "Content-Length: 0",
            ]
        # Normal / API / static / method / burst
        return base + [
            "X-Frame-Options: SAMEORIGIN",
            "X-Content-Type-Options: nosniff",
            "Strict-Transport-Security: max-age=31536000; includeSubDomains",
            "Content-Security-Policy: default-src 'self'",
            "Cache-Control: no-store; no-cache; must-revalidate",
            "X-XSS-Protection: 1; mode=block",
            "Referrer-Policy: strict-origin-when-cross-origin",
            f"Content-Type: {'application/json' if scenario == 'api' else 'text/html'}; charset=utf-8",
            f"Content-Length: {random.randint(200, 15000)}",
            "Connection: keep-alive",
        ]

    for i, (scenario, host, method, ua, scheme) in enumerate(scenarios):
        if scenario == "bot":
            status, connect, tls = 403, random.randint(8, 15), random.randint(30, 50)
            ttfb = random.randint(10, 25)
            total = ttfb + random.randint(1, 5)
            blocked = True
        elif scenario == "redirect":
            status, connect, tls = 301, random.randint(8, 15), 0
            ttfb = random.randint(8, 20)
            total = ttfb + random.randint(1, 3)
            blocked = False
        elif scenario == "cors":
            status, connect, tls = 200, random.randint(8, 15), random.randint(30, 50)
            ttfb = random.randint(12, 30)
            total = ttfb + random.randint(2, 5)
            blocked = False
        else:
            status, connect = 200, random.randint(8, 18)
            tls = random.randint(30, 55)
            if is_candidate:
                ttfb = random.randint(80, 180)
                total = ttfb + random.randint(5, 30)
            else:
                ttfb = random.randint(50, 120)
                total = ttfb + random.randint(3, 20)
            blocked = False

        rows.append({
            "request_num": i + 1, "scenario": scenario, "host": host,
            "method": method, "user_agent": ua, "http_status": status,
            "time_connect_ms": connect, "time_tls_ms": tls,
            "time_ttfb_ms": ttfb, "time_total_ms": total,
            "blocked": str(blocked).lower(),
            "response_headers": "|".join(sample_headers(scenario, status)),
        })
    return rows


# ═══ Main ═══

# Create directory structure
os.makedirs(f"{OUT}/diffs", exist_ok=True)
os.makedirs(f"{OUT}/logs/baseline", exist_ok=True)
os.makedirs(f"{OUT}/logs/candidate", exist_ok=True)

# Generate test results
baseline_results = build_results(is_candidate=False)
candidate_results = build_results(is_candidate=True)

baseline_json = build_json("10.0.1.5", "vpx-baseline", baseline_results)
candidate_json = build_json("10.0.1.6", "vpx-candidate", candidate_results)

print(f"Baseline:  {baseline_json['total']} tests ({baseline_json['passed']}P / {baseline_json['failed']}F / {baseline_json['warnings']}W)")
print(f"Candidate: {candidate_json['total']} tests ({candidate_json['passed']}P / {candidate_json['failed']}F / {candidate_json['warnings']}W)")

with open(f"{OUT}/baseline.json", "w") as f:
    json.dump(baseline_json, f, indent=2)
with open(f"{OUT}/candidate.json", "w") as f:
    json.dump(candidate_json, f, indent=2)

# Generate diffs
diffs = generate_diffs()
for name, content in diffs.items():
    filename = name.replace(" ", "_").replace("/", "_") + ".diff"
    with open(f"{OUT}/diffs/{filename}", "w") as f:
        f.write(content)
print(f"Diffs:     {len(diffs)} CLI diff files")

# Generate metrics
import csv
metrics = generate_metrics()
with open(f"{OUT}/metrics.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["timestamp", "cpu_pct", "mem_pct", "net_rx_mbps", "net_tx_mbps", "disk_pct"])
    w.writeheader()
    w.writerows(metrics)
print(f"Metrics:   {len(metrics)} samples ({len(metrics) * 10 // 60} minutes)")

# Generate logs
logs = generate_logs()
for (vpx, filename), content in logs.items():
    with open(f"{OUT}/logs/{vpx}/{filename}", "w") as f:
        f.write(content)
print(f"Logs:      {len(logs)} log files")

# Generate probe timing CSVs (50 requests each)
probe_fields = ["request_num", "scenario", "host", "method", "user_agent",
                "http_status", "time_connect_ms", "time_tls_ms",
                "time_ttfb_ms", "time_total_ms", "blocked", "response_headers"]
for label, is_cand in [("baseline", False), ("candidate", True)]:
    probe_rows = generate_probe_timings(is_candidate=is_cand)
    probe_path = f"{OUT}/{label}-probe-timings.csv"
    with open(probe_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=probe_fields)
        w.writeheader()
        w.writerows(probe_rows)
    blocked = sum(1 for r in probe_rows if r["blocked"] == "true")
    avg_ttfb = sum(r["time_ttfb_ms"] for r in probe_rows) // len(probe_rows)
    print(f"Probes:    {label}: {len(probe_rows)} requests, {blocked} blocked, avg TTFB {avg_ttfb}ms")

print(f"\nAll sample data written to {OUT}/")
