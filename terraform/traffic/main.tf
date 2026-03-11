# NetScaler VPX Traffic Configuration
# VIP pointing to httpbin.org backend with HTTPS, HTTP redirect,
# security headers, request enrichment, and bot blocking.

# ============================================================
# CERTIFICATES
# ============================================================

resource "citrixadc_systemfile" "lab_ca_crt" {
  filename     = "lab-ca.crt"
  filelocation = "/nsconfig/ssl"
  filecontent  = base64decode(var.lab_ca_crt)
}

resource "citrixadc_systemfile" "wildcard_crt" {
  filename     = "wildcard.crt"
  filelocation = "/nsconfig/ssl"
  filecontent  = base64decode(var.wildcard_crt)
}

resource "citrixadc_systemfile" "wildcard_key" {
  filename     = "wildcard.key"
  filelocation = "/nsconfig/ssl"
  filecontent  = base64decode(var.wildcard_key)
}

resource "citrixadc_sslcertkey" "lab_ca" {
  certkey = "lab-ca"
  cert    = "/nsconfig/ssl/lab-ca.crt"

  depends_on = [citrixadc_systemfile.lab_ca_crt]
}

resource "citrixadc_sslcertkey" "wildcard" {
  certkey = "wildcard"
  cert    = "/nsconfig/ssl/wildcard.crt"
  key     = "/nsconfig/ssl/wildcard.key"
  linkcertkeyname = citrixadc_sslcertkey.lab_ca.certkey

  depends_on = [
    citrixadc_systemfile.wildcard_crt,
    citrixadc_systemfile.wildcard_key,
  ]

  lifecycle {
    replace_triggered_by = [
      citrixadc_systemfile.wildcard_crt,
      citrixadc_systemfile.wildcard_key,
    ]
  }
}

# ============================================================
# BACKEND — httpbin.org
# ============================================================

resource "citrixadc_server" "httpbin" {
  name   = "srv_httpbin"
  domain = "httpbin.org"
}

resource "citrixadc_servicegroup" "backend" {
  servicegroupname = "sg_backend"
  servicetype      = "SSL"
  cip              = "ENABLED"
  cipheader        = "X-Forwarded-For"
}

resource "citrixadc_servicegroup_servicegroupmember_binding" "httpbin" {
  servicegroupname = citrixadc_servicegroup.backend.servicegroupname
  servername       = citrixadc_server.httpbin.name
  port             = 443
}

# Health monitor — GET /get on httpbin.org
resource "citrixadc_lbmonitor" "https_health" {
  monitorname   = "mon_https_health"
  type          = "HTTP"
  httprequest   = "GET /get"
  respcode      = ["200"]
  secure        = "YES"
  interval      = 30
  resptimeout   = 10
  retries       = 3
}

resource "citrixadc_servicegroup_lbmonitor_binding" "health" {
  servicegroupname = citrixadc_servicegroup.backend.servicegroupname
  monitorname      = citrixadc_lbmonitor.https_health.monitorname
}

# ============================================================
# LB VSERVERS
# ============================================================

# HTTPS VServer (main traffic)
resource "citrixadc_lbvserver" "https" {
  name        = "lb_vsrv_https"
  ipv46       = var.vip
  port        = 443
  servicetype = "SSL"
  lbmethod    = "ROUNDROBIN"
  persistencetype = "NONE"
  httpprofilename = "nshttp_hardened"
  tcpprofilename  = "nstcp_hardened"
}

resource "citrixadc_lbvserver_servicegroup_binding" "https" {
  name             = citrixadc_lbvserver.https.name
  servicegroupname = citrixadc_servicegroup.backend.servicegroupname
}

# SSL cert binding
resource "citrixadc_sslvserver_sslcertkey_binding" "wildcard" {
  vservername = citrixadc_lbvserver.https.name
  certkeyname = citrixadc_sslcertkey.wildcard.certkey
}

# ============================================================
# CIPHER SUITES
# ============================================================

resource "citrixadc_sslvserver_sslciphersuite_binding" "tls12_ecdhe_aes256" {
  vservername = citrixadc_lbvserver.https.name
  ciphername  = "TLS1.2-ECDHE-RSA-AES256-GCM-SHA384"
}

resource "citrixadc_sslvserver_sslciphersuite_binding" "tls12_ecdhe_aes128" {
  vservername = citrixadc_lbvserver.https.name
  ciphername  = "TLS1.2-ECDHE-RSA-AES128-GCM-SHA256"
}

resource "citrixadc_sslvserver_sslciphersuite_binding" "tls13_aes256" {
  vservername = citrixadc_lbvserver.https.name
  ciphername  = "TLS1.3-AES256-GCM-SHA384"
}

resource "citrixadc_sslvserver_sslciphersuite_binding" "tls13_aes128" {
  vservername = citrixadc_lbvserver.https.name
  ciphername  = "TLS1.3-AES128-GCM-SHA256"
}

# HTTP VServer (redirect only — needs a service bound to go UP)
resource "citrixadc_lbvserver" "http" {
  name        = "lb_vsrv_http"
  ipv46       = var.vip
  port        = 80
  servicetype = "HTTP"
  lbmethod    = "ROUNDROBIN"
}

resource "citrixadc_lbvserver_servicegroup_binding" "http" {
  name             = citrixadc_lbvserver.http.name
  servicegroupname = citrixadc_servicegroup.backend.servicegroupname
}

# ============================================================
# HTTP -> HTTPS REDIRECT
# ============================================================

resource "citrixadc_responderaction" "redirect_https" {
  name   = "act_redirect_https"
  type   = "redirect"
  target = "\"https://\" + HTTP.REQ.HOSTNAME + HTTP.REQ.URL.PATH_AND_QUERY"
  responsestatuscode = 301
}

resource "citrixadc_responderpolicy" "redirect_https" {
  name   = "pol_redirect_https"
  rule   = "HTTP.REQ.IS_VALID"
  action = citrixadc_responderaction.redirect_https.name
}

resource "citrixadc_lbvserver_responderpolicy_binding" "redirect_https" {
  name       = citrixadc_lbvserver.http.name
  policyname = citrixadc_responderpolicy.redirect_https.name
  priority   = 100
  bindpoint  = "REQUEST"
}

# ============================================================
# SECURITY HEADERS (RESPONSE)
# ============================================================

# --- HSTS ---
resource "citrixadc_rewriteaction" "hsts" {
  name   = "act_hsts"
  type   = "insert_http_header"
  target = "Strict-Transport-Security"
  stringbuilderexpr = "\"max-age=31536000; includeSubDomains\""
}

resource "citrixadc_rewritepolicy" "hsts" {
  name   = "pol_hsts"
  rule   = "true"
  action = citrixadc_rewriteaction.hsts.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "hsts" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.hsts.name
  priority                = 100
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- X-Frame-Options ---
resource "citrixadc_rewriteaction" "xfo" {
  name   = "act_xfo"
  type   = "insert_http_header"
  target = "X-Frame-Options"
  stringbuilderexpr = "\"DENY\""
}

resource "citrixadc_rewritepolicy" "xfo" {
  name   = "pol_xfo"
  rule   = "true"
  action = citrixadc_rewriteaction.xfo.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "xfo" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.xfo.name
  priority                = 110
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- X-Content-Type-Options ---
resource "citrixadc_rewriteaction" "xcto" {
  name   = "act_xcto"
  type   = "insert_http_header"
  target = "X-Content-Type-Options"
  stringbuilderexpr = "\"nosniff\""
}

resource "citrixadc_rewritepolicy" "xcto" {
  name   = "pol_xcto"
  rule   = "true"
  action = citrixadc_rewriteaction.xcto.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "xcto" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.xcto.name
  priority                = 120
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- X-XSS-Protection ---
resource "citrixadc_rewriteaction" "xxss" {
  name   = "act_xxss"
  type   = "insert_http_header"
  target = "X-XSS-Protection"
  stringbuilderexpr = "\"1; mode=block\""
}

resource "citrixadc_rewritepolicy" "xxss" {
  name   = "pol_xxss"
  rule   = "true"
  action = citrixadc_rewriteaction.xxss.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "xxss" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.xxss.name
  priority                = 130
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- Referrer-Policy ---
resource "citrixadc_rewriteaction" "referrer" {
  name   = "act_referrer_policy"
  type   = "insert_http_header"
  target = "Referrer-Policy"
  stringbuilderexpr = "\"strict-origin-when-cross-origin\""
}

resource "citrixadc_rewritepolicy" "referrer" {
  name   = "pol_referrer_policy"
  rule   = "true"
  action = citrixadc_rewriteaction.referrer.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "referrer" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.referrer.name
  priority                = 140
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- Permissions-Policy ---
resource "citrixadc_rewriteaction" "permissions" {
  name   = "act_permissions_policy"
  type   = "insert_http_header"
  target = "Permissions-Policy"
  stringbuilderexpr = "\"geolocation=(), camera=(), microphone=()\""
}

resource "citrixadc_rewritepolicy" "permissions" {
  name   = "pol_permissions_policy"
  rule   = "true"
  action = citrixadc_rewriteaction.permissions.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "permissions" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.permissions.name
  priority                = 150
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- Content-Security-Policy ---
resource "citrixadc_rewriteaction" "csp" {
  name   = "act_csp"
  type   = "insert_http_header"
  target = "Content-Security-Policy"
  stringbuilderexpr = "\"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'\""
}

resource "citrixadc_rewritepolicy" "csp" {
  name   = "pol_csp"
  rule   = "true"
  action = citrixadc_rewriteaction.csp.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "csp" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.csp.name
  priority                = 160
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- Delete Server header ---
resource "citrixadc_rewriteaction" "del_server" {
  name   = "act_del_server"
  type   = "delete_http_header"
  target = "Server"
}

resource "citrixadc_rewritepolicy" "del_server" {
  name   = "pol_del_server"
  rule   = "true"
  action = citrixadc_rewriteaction.del_server.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "del_server" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.del_server.name
  priority                = 170
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# --- Delete X-Powered-By header ---
resource "citrixadc_rewriteaction" "del_powered" {
  name   = "act_del_xpoweredby"
  type   = "delete_http_header"
  target = "X-Powered-By"
}

resource "citrixadc_rewritepolicy" "del_powered" {
  name   = "pol_del_xpoweredby"
  rule   = "true"
  action = citrixadc_rewriteaction.del_powered.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "del_powered" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.del_powered.name
  priority                = 180
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# ============================================================
# REQUEST HEADERS
# ============================================================

# --- X-Forwarded-For ---
resource "citrixadc_rewriteaction" "xff" {
  name   = "act_xff"
  type   = "insert_http_header"
  target = "X-Forwarded-For"
  stringbuilderexpr = "CLIENT.IP.SRC"
}

resource "citrixadc_rewritepolicy" "xff" {
  name   = "pol_xff"
  rule   = "true"
  action = citrixadc_rewriteaction.xff.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "xff" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.xff.name
  priority                = 100
  bindpoint               = "REQUEST"
  gotopriorityexpression  = "NEXT"
}

# --- X-Real-IP ---
resource "citrixadc_rewriteaction" "xrip" {
  name   = "act_xrealip"
  type   = "insert_http_header"
  target = "X-Real-IP"
  stringbuilderexpr = "CLIENT.IP.SRC"
}

resource "citrixadc_rewritepolicy" "xrip" {
  name   = "pol_xrealip"
  rule   = "true"
  action = citrixadc_rewriteaction.xrip.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "xrip" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.xrip.name
  priority                = 110
  bindpoint               = "REQUEST"
  gotopriorityexpression  = "NEXT"
}

# --- X-Forwarded-Proto ---
resource "citrixadc_rewriteaction" "xfp" {
  name   = "act_xfproto"
  type   = "insert_http_header"
  target = "X-Forwarded-Proto"
  stringbuilderexpr = "\"https\""
}

resource "citrixadc_rewritepolicy" "xfp" {
  name   = "pol_xfproto"
  rule   = "true"
  action = citrixadc_rewriteaction.xfp.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "xfp" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.xfp.name
  priority                = 120
  bindpoint               = "REQUEST"
  gotopriorityexpression  = "NEXT"
}

# --- X-Request-ID (hex format for trace correlation) ---
resource "citrixadc_rewriteaction" "xrid" {
  name              = "act_xrequestid"
  type              = "insert_http_header"
  target            = "X-Request-ID"
  stringbuilderexpr = "SYS.TIME + \"-\" + SYS.RANDOM"
}

resource "citrixadc_rewritepolicy" "xrid" {
  name   = "pol_xrequestid"
  rule   = "true"
  action = citrixadc_rewriteaction.xrid.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "xrid" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.xrid.name
  priority                = 130
  bindpoint               = "REQUEST"
  gotopriorityexpression  = "NEXT"
}

# ============================================================
# BOT BLOCKING
# ============================================================

resource "citrixadc_policypatset" "bad_useragents" {
  name = "ps_bad_useragents"
}

resource "citrixadc_policypatset_pattern_binding" "sqlmap" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "sqlmap"
}

resource "citrixadc_policypatset_pattern_binding" "nikto" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "nikto"
}

resource "citrixadc_policypatset_pattern_binding" "nmap" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "nmap"
}

resource "citrixadc_policypatset_pattern_binding" "masscan" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "masscan"
}

resource "citrixadc_policypatset_pattern_binding" "dirbuster" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "dirbuster"
}

resource "citrixadc_policypatset_pattern_binding" "gobuster" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "gobuster"
}

resource "citrixadc_policypatset_pattern_binding" "wpscan" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "wpscan"
}

resource "citrixadc_policypatset_pattern_binding" "nuclei" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "nuclei"
}

resource "citrixadc_policypatset_pattern_binding" "zmeu" {
  name    = citrixadc_policypatset.bad_useragents.name
  string  = "ZmEu"
}

resource "citrixadc_responderaction" "block_bot" {
  name   = "act_block_bot"
  type   = "respondwith"
  target = "\"HTTP/1.1 403 Forbidden\\r\\n\\r\\n\""
}

resource "citrixadc_responderpolicy" "block_bot" {
  name   = "pol_block_bot"
  rule   = "HTTP.REQ.HEADER(\"User-Agent\").CONTAINS_ANY(\"ps_bad_useragents\")"
  action = citrixadc_responderaction.block_bot.name
}

resource "citrixadc_lbvserver_responderpolicy_binding" "block_bot" {
  name       = citrixadc_lbvserver.https.name
  policyname = citrixadc_responderpolicy.block_bot.name
  priority   = 100
  bindpoint  = "REQUEST"
}

# ============================================================
# X-REQUEST-ID ECHO (response header for client correlation)
# ============================================================

resource "citrixadc_rewriteaction" "rid_response" {
  name              = "act_rid_response"
  type              = "insert_http_header"
  target            = "X-Request-ID"
  stringbuilderexpr = "HTTP.REQ.HEADER(\"X-Request-ID\")"
}

resource "citrixadc_rewritepolicy" "rid_response" {
  name   = "pol_rid_response"
  rule   = "HTTP.REQ.HEADER(\"X-Request-ID\").LENGTH.GT(0)"
  action = citrixadc_rewriteaction.rid_response.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "rid_response" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.rid_response.name
  priority                = 192
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "NEXT"
}

# ============================================================
# HTTP TRANSACTION LOGGING
# ============================================================

# Audit message action — logs every HTTP response with full request/response details
resource "citrixadc_auditmessageaction" "http_log" {
  name              = "act_log_http"
  loglevel          = "INFORMATIONAL"
  stringbuilderexpr = "\"HTTP_TX \" + CLIENT.IP.SRC + \":\" + CLIENT.TCP.SRCPORT + \" \" + HTTP.REQ.METHOD + \" \" + HTTP.REQ.HEADER(\"Host\") + HTTP.REQ.URL.PATH_AND_QUERY + \" status=\" + HTTP.RES.STATUS + \" ua=\" + HTTP.REQ.HEADER(\"User-Agent\") + \" cl=\" + HTTP.RES.CONTENT_LENGTH + \" ref=\" + HTTP.REQ.HEADER(\"Referer\")"
  logtonewnslog     = "YES"
}

# NOOP rewrite action (no modification, just triggers logaction)
resource "citrixadc_rewriteaction" "noop_log" {
  name              = "act_noop_log"
  type              = "noop"
  stringbuilderexpr = "\"true\""
}

# Rewrite policy (NOOP action, triggers log on every response)
resource "citrixadc_rewritepolicy" "log_http" {
  name      = "pol_log_http"
  rule      = "true"
  action    = citrixadc_rewriteaction.noop_log.name
  logaction = citrixadc_auditmessageaction.http_log.name
}

resource "citrixadc_lbvserver_rewritepolicy_binding" "log_http" {
  name                    = citrixadc_lbvserver.https.name
  policyname              = citrixadc_rewritepolicy.log_http.name
  priority                = 200
  bindpoint               = "RESPONSE"
  gotopriorityexpression  = "END"
}

# ============================================================
# SAVE CONFIG
# ============================================================

resource "citrixadc_nsconfig_save" "save" {
  all        = true
  timestamp  = timestamp()

  depends_on = [
    citrixadc_lbvserver_servicegroup_binding.https,
    citrixadc_sslvserver_sslcertkey_binding.wildcard,
    citrixadc_sslvserver_sslciphersuite_binding.tls12_ecdhe_aes256,
    citrixadc_sslvserver_sslciphersuite_binding.tls12_ecdhe_aes128,
    citrixadc_sslvserver_sslciphersuite_binding.tls13_aes256,
    citrixadc_sslvserver_sslciphersuite_binding.tls13_aes128,
    citrixadc_lbvserver_responderpolicy_binding.redirect_https,
    citrixadc_lbvserver_responderpolicy_binding.block_bot,
    citrixadc_lbvserver_rewritepolicy_binding.hsts,
    citrixadc_lbvserver_rewritepolicy_binding.del_powered,
    citrixadc_lbvserver_rewritepolicy_binding.xff,
    citrixadc_lbvserver_rewritepolicy_binding.xrid,
    citrixadc_lbvserver_rewritepolicy_binding.rid_response,
    citrixadc_lbvserver_rewritepolicy_binding.log_http,
  ]
}
