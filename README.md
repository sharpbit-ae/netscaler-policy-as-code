# NetScaler Azure VPX

Automated deployment and regression testing of Citrix NetScaler VPX on Azure with Terraform, GitHub Actions, and a comprehensive NITRO API test suite producing interactive HTML reports.

```
                         GitHub Actions
                              |
          +-------------------+-------------------+
          |                   |                   |
    +-----v-----+      +-----v-----+      +------v------+
    | Bootstrap  |      |  Deploy   |      |    Test     |
    |            |      | (2 jobs)  |      |             |
    | VNet       |      |           |      | 375 NITRO   |
    | Runner VM  |      | VPX VM    |      | API tests   |
    | Subnets    |      | Security  |      | 50 HTTP     |
    | NSGs       |      | Traffic   |      | probes      |
    +------------+      | TLS Certs |      | HTML report |
                        +-----+-----+      +-------------+
                              |
              +---------------+---------------+
              |               |               |
        +-----v-----+  +-----v-----+  +------v------+
        |  VPX VM   |  | httpbin   |  |  Regression |
        |           |  | (backend) |  |   Report    |
        | HTTPS LB  |--| httpbin   |  |             |
        | Rewrite   |  | .org/get  |  | Charts      |
        | Bot Block |  |           |  | Diffs       |
        | Sec Hdrs  |  +-----------+  | Modals      |
        +-----------+                 +-------------+
```

## What It Does

1. **Bootstraps** Azure infrastructure: VNet (10.254.0.0/16), 3 subnets, a self-hosted GitHub Actions runner VM, NSGs
2. **Deploys** a NetScaler VPX 14.1 VM with dual NICs (management + client-facing) and auto-generated TLS certificates
3. **Configures** the VPX via Terraform: TLS termination, security headers, bot blocking, request enrichment, HTTP/TCP profile hardening
4. **Tests** the configuration with 375 NITRO API assertions across 16 categories and 50 HTTP probe requests
5. **Produces** a self-contained interactive HTML report with charts, diffs, clickable probe detail modals, and CSV export

## Quick Start

### 1. Bootstrap (one-time)

Run the **Bootstrap Infrastructure** workflow from GitHub Actions with your SSH public key.

**Required secrets:**

| Secret | Purpose |
|--------|---------|
| `ARM_CLIENT_ID` | Azure service principal |
| `ARM_CLIENT_SECRET` | Azure service principal |
| `ARM_TENANT_ID` | Azure AD tenant |
| `ARM_SUBSCRIPTION_ID` | Azure subscription |
| `GH_PAT` | GitHub PAT (runner registration) |
| `NSROOT_PASSWORD` | VPX admin password |
| `RPC_PASSWORD` | VPX RPC node password |

### 2. Deploy & Test

Run the **Deploy & Test NetScaler VPX** workflow. It provisions everything in 4 sequential jobs (~30 minutes):

```
Deploy VPX → Configure (security + traffic) → Regression Tests → Health Check
```

### 3. Demo Mode

Run with `demoMode: true` to generate a sample HTML report without deploying any Azure resources.

## Architecture

### Network Layout

```
10.254.0.0/16 (vnet-vpx)
├── 10.254.1.0/24  (snet-runner)     → Runner VM (GitHub Actions)
├── 10.254.10.0/24 (snet-vpx-mgmt)  → VPX Management NIC (NSIP)
└── 10.254.11.0/24 (snet-vpx-client) → VPX Client NIC (SNIP + VIP)
```

### Traffic Flow

```
Client → VIP Public IP:443 → VPX HTTPS LB VServer
  → TLS termination (wildcard cert, TLS 1.2/1.3)
  → Security headers injected (HSTS, CSP, X-Frame-Options, ...)
  → Bot check (block sqlmap, nikto, nmap, nuclei, etc.)
  → Request headers enriched (X-Forwarded-For, X-Real-IP, X-Request-ID)
  → Proxy to httpbin.org backend (SSL)
  → Response returned with security headers + X-Request-ID echo
```

### Components

| Component | Where | Purpose |
|-----------|-------|---------|
| **VPX VM** | Azure (Standard_D2s_v3) | NetScaler 14.1 — LB, TLS, rewrite, bot blocking |
| **httpbin.org** | External | Backend endpoint (`/get`) |
| **Runner VM** | Azure (Standard_B1s) | GitHub Actions self-hosted runner |
| **TLS Certs** | Terraform TLS provider | Self-signed lab CA + wildcard cert (auto-generated) |

## Terraform Modules

4 modules, ~50 resources total:

### `bootstrap/` — Azure Foundation

VNet, 3 subnets, runner VM (Ubuntu 22.04, cloud-init with Docker + Terraform + Azure CLI + GitHub runner), NSGs, public IP.

### `deploy/` — VPX VM + TLS Certificates

Citrix VPX 14.1 BYOL marketplace image with dual NICs:
- **Management**: Private 10.254.10.10 + public IP, SSH/HTTPS from runner only
- **Client**: SNIP 10.254.11.10 + VIP 10.254.11.11 + public IP, HTTP/HTTPS from any

Auto-generates TLS certificates using the Terraform TLS provider:
- Self-signed lab CA (RSA 2048, 1 year)
- Wildcard certificate for `*.lab.local` signed by lab CA

### `security/` — VPX Hardening

| Category | Configuration |
|----------|--------------|
| Features | LB, CS, SSL, Rewrite, Responder, CMP |
| Modes | FR, TCPB, Edge, L3, ULFD |
| HTTP Profile | Drop invalid requests, block HTTP/0.9, CONNECT, TRACE. HTTP/2 (128 streams) |
| TCP Profile | CUBIC, SACK, ECN, D-SACK, F-RTO, SYN flood drop, RST attenuation |
| System | Strong passwords, 900s timeout, basic auth disabled |

### `traffic/` — Full ADC Configuration

**TLS**: Lab CA + wildcard cert upload, chain linking. 4 AEAD cipher suites.

**Load Balancing**: HTTPS vserver (VIP:443, RoundRobin) + HTTP vserver (VIP:80, redirect-only). DNS-based backend server resolving to httpbin.org.

**Security** (9 rewrite policies): HSTS, X-Frame-Options DENY, X-Content-Type-Options, X-XSS-Protection, Referrer-Policy, Permissions-Policy, CSP, remove Server/X-Powered-By headers.

**Request Enrichment**: X-Forwarded-For, X-Real-IP, X-Forwarded-Proto, X-Request-ID generation.

**Bot Blocking**: Pattern set with 9 attack tool signatures → 403 Forbidden.

## Regression Tests

### NITRO API Tests (375 assertions, 16 categories)

Each Terraform-managed resource is queried via NITRO REST API and validated:

| Category | Tests | What's Validated |
|----------|-------|-----------------|
| System | 4 | Hostname, DNS servers, NTP |
| Security | 7 | Strong password, session timeout, RPC encryption |
| Features | 9 | LB, CS, SSL, Rewrite, Responder, CMP |
| Modes | 5 | FR, TCPB, Edge, L3, ULFD |
| HTTP Profiles | 8 | Hardened + custom (HTTP/2, invalid request handling) |
| TCP Profiles | 8 | RST attenuation, SYN spoof, ECN, timestamps |
| SSL Profiles | 8 | TLS 1.2+, HSTS, cipher priorities |
| Certificates | 6 | CertKey objects, file paths, chain validation |
| Servers | 2 | Backend server objects and IPs |
| Monitors | 5 | Health check types, intervals, retries |
| Service Groups | 6 | Service types, member bindings |
| LB VServers | 7 | LB method, persistence, profile bindings |
| CS VServers | 4 | Content-switching config, SSL bindings |
| Bindings | 50+ | All SG, LB, CS, rewrite/responder bindings |
| Deep Values | 30+ | TCP window sizes, HTTP/2 streams, monitor intervals |

### HTTP Probe Requests (50 per VPX)

50 real HTTP requests across 8 scenarios:

| Requests | Scenario | What's Tested |
|----------|----------|--------------|
| 1–10 | Normal | Standard browsing |
| 11–15 | API | API endpoint routing |
| 16–20 | Static | Static content routing |
| 21–25 | Redirect | HTTP→HTTPS redirect (port 80) |
| 26–35 | Bot | 10 attack tool user-agents (should return 403) |
| 36–38 | CORS | OPTIONS preflight requests |
| 39–42 | Methods | POST, PUT, DELETE, PATCH |
| 43–50 | Burst | Rapid back-to-back requests |

Each probe captures: HTTP status, TCP connect time, TLS handshake time, TTFB, total time, and full response headers.

## HTML Report

Self-contained HTML file published as a GitHub Actions artifact:

- **SVG donut charts** — pass/fail/warning per test category
- **Category breakdown** — stacked bar chart per category
- **Failures & warnings** — prominent section with full test details
- **HTTP load profile** — SVG bar chart with timing breakdown
- **Clickable probe detail modal** — click any bar for full metadata, timing (Connect/TLS/Server/Transfer visual bar), and response headers
- **Security headers checklist** — header comparison table
- **Passed tests** — collapsible section with full-text search filter
- **CSV export** — one-click download of all results

## Security

- **TLS**: 1.2/1.3 only, 4 AEAD ciphers (ECDHE-RSA-AES256/128-GCM, TLS 1.3 AES256/128-GCM)
- **Headers**: HSTS (1 year), CSP, X-Frame-Options DENY, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, Server/X-Powered-By removed
- **Bot blocking**: 9 attack tool signatures (sqlmap, nikto, nmap, nuclei, masscan, dirbuster, gobuster, wpscan, ZmEu)
- **VPX hardening**: Strong passwords, 900s timeout, basic auth disabled, HTTP/TCP profile hardening
- **Network**: NSGs restrict management access to runner subnet only
- **Credentials**: Passwords via GitHub Actions secrets, TLS certs auto-generated by Terraform — no secrets in repo

## Project Structure

```
.github/workflows/
  bootstrap.yml                    One-time: VNet, subnets, runner VM, GitHub runner registration
  deploy.yml                       Main: 4-job pipeline (deploy → configure → test → healthcheck)

terraform/
  bootstrap/
    main.tf                        VNet, 3 subnets, runner VM (cloud-init), NSGs, public IP
    cloud-init.yaml                Docker, Terraform 1.9.8, Azure CLI, GitHub runner setup
    variables.tf / outputs.tf / versions.tf
  deploy/
    main.tf                        VPX VM (14.1 BYOL), dual NICs, public IPs, TLS cert generation
    variables.tf / outputs.tf / versions.tf
  security/
    main.tf                        Features, modes, system params, HTTP/TCP profiles
    variables.tf / outputs.tf / versions.tf
  traffic/
    main.tf                        Certs, httpbin backend, LB vservers, SSL, security headers,
                                   request enrichment, bot blocking, X-Request-ID echo
    variables.tf / outputs.tf / versions.tf

scripts/
  run-comprehensive-tests.sh       375 NITRO API tests (16 categories) + 50 HTTP probes
  generate-html-report.py          Interactive HTML report (charts, diffs, modals, export)
  generate-sample-data.py          Demo mode: realistic sample data without VPX hardware
  generate-junit-report.py         Convert results to JUnit XML for GitHub test reporting
  collect-metrics.sh               Background CPU/RAM/disk/network sampler
  ssh-vpx.sh / ssh-vpx.exp         SSH wrappers for VPX keyboard-interactive auth
  wait-for-nitro.sh                NITRO API poller (HTTPS→HTTP fallback)
```
