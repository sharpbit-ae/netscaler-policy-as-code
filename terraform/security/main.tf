# NetScaler VPX Base Security Hardening
# Configures features, modes, system parameters, profiles, SNIP, and timeouts.
# Run AFTER the VPX VM is deployed and reachable.

# --- Features & Modes ---
resource "citrixadc_nsfeature" "features" {
  lb        = true
  cs        = true
  ssl       = true
  rewrite   = true
  responder = true
  cmp       = true
}

resource "citrixadc_nsmode" "modes" {
  fr   = true
  tcpb = true
  edge = true
  l3   = true
  ulfd = true
}

# --- System Parameters ---
resource "citrixadc_systemparameter" "hardening" {
  minpasswordlen          = 8
  strongpassword          = "enableall"
  maxclient               = 10
  timeout                 = 900
  restrictedtimeout       = "enabled"
  basicauth               = "disabled"
  reauthonauthparamchange = "enabled"
}

# --- SNIP (Subnet IP for outbound traffic) ---
resource "citrixadc_nsip" "snip" {
  ipaddress = var.snip
  netmask   = "255.255.255.0"
  type      = "SNIP"
}

# --- HTTP Profile (hardened) ---
resource "citrixadc_nshttpprofile" "hardened" {
  name              = "nshttp_hardened"
  dropinvalreqs     = "ENABLED"
  markhttp09inval   = "ENABLED"
  markconnreqinval  = "ENABLED"
  marktracereqinval = "ENABLED"
  conmultiplex      = "ENABLED"
  http2             = "ENABLED"
  http2maxconcurrentstreams = 128
}

# --- TCP Profile (hardened) ---
resource "citrixadc_nstcpprofile" "hardened" {
  name                = "nstcp_hardened"
  ws                  = "ENABLED"
  sack                = "ENABLED"
  nagle               = "DISABLED"
  ecn                 = "ENABLED"
  dsack               = "ENABLED"
  frto                = "ENABLED"
  spoofsyndrop        = "ENABLED"
  rstwindowattenuate  = "ENABLED"
  initialcwnd         = 16
  oooqsize            = 300
  ka                  = "ENABLED"
  kaconnidletime      = 900
  flavor              = "CUBIC"
}

# --- Timeouts ---
resource "citrixadc_nstimeout" "timeouts" {
  zombie       = 600
  halfclose    = 300
  nontcpzombie = 300
}

# --- Save Config ---
resource "citrixadc_nsconfig_save" "save" {
  all       = true
  timestamp = timestamp()

  depends_on = [
    citrixadc_nsfeature.features,
    citrixadc_nsmode.modes,
    citrixadc_systemparameter.hardening,
    citrixadc_nsip.snip,
    citrixadc_nshttpprofile.hardened,
    citrixadc_nstcpprofile.hardened,
    citrixadc_nstimeout.timeouts,
  ]
}
