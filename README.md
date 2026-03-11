# NetScaler Azure VPX

Automated deployment and regression testing of Citrix NetScaler VPX on Azure. Terraform provisions the VPX, configures it with security hardening and httpbin.org backend, then runs 375 NITRO API tests with results streamed to GitHub Actions logs.

```
  Local Machine (GitHub Actions Runner)
         |
         |  terraform apply
         |  NITRO API tests
         |  HTTP probes
         v
  +------+------+
  | Azure       |
  |             |
  | VNet        |
  | +--------+  |        +-----------+
  | | VPX VM |--+------->| httpbin   |
  | | :443   |  |  SSL   | .org/get  |
  | +--------+  |        +-----------+
  |             |
  +-------------+
```

## What It Does

1. **Deploys** a NetScaler VPX 14.1 VM on Azure with dual NICs, VNet, and auto-generated TLS certificates
2. **Configures** the VPX via Terraform: TLS termination, security headers, bot blocking, request enrichment, HTTP/TCP profile hardening
3. **Tests** the configuration with 375 NITRO API assertions and 50 HTTP probe requests
4. **Reports** all test results directly in GitHub Actions logs

## Prerequisites

- Self-hosted GitHub Actions runner on your local machine (registered to this repo)
- Terraform, Azure CLI, Python 3 installed locally
- Azure service principal with contributor access

## Setup

### 1. Register GitHub Actions Runner

```bash
# Download runner
mkdir ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64-2.332.0.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# Configure (get token from repo Settings → Actions → Runners)
./config.sh --url https://github.com/YOUR_ORG/netscaler-azure-vpx \
  --token YOUR_TOKEN --name kvm-host --labels self-hosted,Linux --unattended

# Install as service
sudo ./svc.sh install $USER
sudo ./svc.sh start
```

### 2. Configure GitHub Secrets

| Secret | Purpose |
|--------|---------|
| `ARM_CLIENT_ID` | Azure service principal |
| `ARM_CLIENT_SECRET` | Azure service principal |
| `ARM_TENANT_ID` | Azure AD tenant |
| `ARM_SUBSCRIPTION_ID` | Azure subscription |
| `NSROOT_PASSWORD` | VPX admin password |
| `RPC_PASSWORD` | VPX RPC node password |

### 3. Deploy & Test

Run the **Deploy & Test NetScaler VPX** workflow from GitHub Actions. It runs 4 jobs (~30 minutes):

```
Deploy VPX → Configure (security + traffic) → Regression Tests → Health Check
```

Test results appear directly in the GitHub Actions log output.

### Demo Mode

Run with `demoMode: true` to generate sample test output without deploying any Azure resources.

## Architecture

### Network Layout

```
10.254.0.0/16 (vnet-vpx)  — created by terraform/deploy
├── 10.254.10.0/24 (snet-vpx-mgmt)   → VPX Management NIC (NSIP) + public IP
└── 10.254.11.0/24 (snet-vpx-client)  → VPX Client NIC (SNIP + VIP) + public IP
```

### Traffic Flow

```
Client → VIP Public IP:443 → VPX HTTPS LB VServer
  → TLS termination (wildcard cert, TLS 1.2/1.3)
  → Security headers (HSTS, CSP, X-Frame-Options, ...)
  → Bot check (block sqlmap, nikto, nmap, nuclei, etc.)
  → Request enrichment (X-Forwarded-For, X-Real-IP, X-Request-ID)
  → Proxy to httpbin.org (SSL)
  → Response with security headers + X-Request-ID echo
```

## Terraform Modules

### `deploy/` — VPX VM + Networking + TLS Certs

VNet (10.254.0.0/16), 2 subnets, NSGs, VPX 14.1 BYOL VM with dual NICs, public IPs, boot diagnostics. Auto-generates lab CA + wildcard cert via Terraform TLS provider.

Management NSG allows SSH/HTTPS from any (runner is external to Azure). Client NSG allows HTTP/HTTPS from any.

### `security/` — VPX Hardening

Features (LB, CS, SSL, Rewrite, Responder, CMP), modes (FR, TCPB, Edge, L3, ULFD), HTTP profile (drop invalid, HTTP/2), TCP profile (CUBIC, SACK, ECN, SYN flood), system params (strong passwords, 900s timeout).

### `traffic/` — ADC Configuration

TLS certs, httpbin.org backend with health monitor, HTTPS + HTTP vservers, 4 AEAD cipher suites, 9 security header policies, 4 request enrichment policies, 9 bot blocking signatures, X-Request-ID echo, HTTP→HTTPS redirect.

## Test Suite

### NITRO API Tests (375 assertions, 16 categories)

| Category | Tests | What's Validated |
|----------|-------|-----------------|
| System | 4 | Hostname, DNS, NTP |
| Security | 7 | Passwords, timeout, RPC |
| Features | 9 | LB, CS, SSL, Rewrite, Responder, CMP |
| Modes | 5 | FR, TCPB, Edge, L3, ULFD |
| HTTP/TCP/SSL Profiles | 24 | Hardening, HTTP/2, TLS 1.2+ |
| Certificates | 6 | CertKey objects, chains |
| LB/CS VServers | 11 | Methods, bindings, policies |
| Bindings | 50+ | All policy and service bindings |

### HTTP Probes (50 requests, 8 scenarios)

Normal browsing, API routing, static content, HTTP→HTTPS redirect, bot blocking (10 attack tools → 403), CORS, HTTP methods, burst.

## Security

- **TLS**: 1.2/1.3 only, 4 AEAD ciphers
- **Headers**: HSTS, CSP, X-Frame-Options DENY, X-Content-Type-Options, Referrer-Policy, Permissions-Policy
- **Bot blocking**: 9 attack tool signatures (sqlmap, nikto, nmap, nuclei, masscan, dirbuster, gobuster, wpscan, ZmEu)
- **VPX hardening**: Strong passwords, 900s timeout, HTTP/TCP profile hardening
- **NSG**: Management allows SSH/HTTPS, client allows HTTP/HTTPS
- **Credentials**: Passwords via GitHub secrets, TLS certs auto-generated — no secrets in repo

## Project Structure

```
.github/workflows/
  deploy.yml                       4-job pipeline (deploy → configure → test → healthcheck)

terraform/
  deploy/
    main.tf                        VNet, subnets, NSGs, VPX VM, NICs, public IPs, TLS certs
    variables.tf / outputs.tf / versions.tf
  security/
    main.tf                        Features, modes, system params, HTTP/TCP profiles
    variables.tf / outputs.tf / versions.tf
  traffic/
    main.tf                        Certs, httpbin backend, LB vservers, SSL, security headers,
                                   request enrichment, bot blocking, X-Request-ID echo
    variables.tf / outputs.tf / versions.tf

scripts/
  run-comprehensive-tests.sh       375 NITRO API tests + 50 HTTP probes
  generate-html-report.py          HTML report generator (optional)
  generate-sample-data.py          Demo mode sample data
  generate-junit-report.py         JUnit XML generator (optional)
  collect-metrics.sh               Host metrics sampler
  ssh-vpx.sh / ssh-vpx.exp         SSH wrappers for VPX auth
  wait-for-nitro.sh                NITRO API poller
```
