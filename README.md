# Nginx WAF Hardened

[![Build](https://github.com/jbsky/nginx-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/nginx-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/nginx-waf-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/nginx-waf-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/nginx-hardened#security--verification)

Image Docker Nginx compilee from source, hardenee (FROM scratch, Go init, tini PID 1), avec WAF ModSecurity + OWASP CRS.

## Modules inclus

| Module | Fonction |
|--------|----------|
| ModSecurity v3 | WAF en mode blocking |
| OWASP Core Rule Set | Regles de securite WAF (auto-updated) |
| GeoIP2 | Blocage geographique (db-ip free) |
| VTS | Monitoring trafic (`/vts-status`) |
| headers-more | Controle complet des headers HTTP |

## Hardening

| Mesure | Detail |
|--------|--------|
| FROM scratch | Zero shell, zero package manager dans l'image finale |
| Go static init | Binary entrypoint + healthcheck HTTP /healthz |
| tini PID 1 | Signal forwarding + zombie reaping |
| Non-root | uid 1999 |
| Compilation hardenee | RELRO, PIE, SSP, FORTIFY_SOURCE, -fPIC, stack-clash, NX |
| GPG verification | Tarball nginx verifie (cles embarquees dans le repo) |
| server_tokens off | Pas de version Nginx dans les headers |
| ModSecurity blocking | WAF actif, pas seulement detection |
| Rate + connection limiting | Anti-DDoS layer 7 |
| Anti-slowloris | Timeouts client agressifs |
| Bot blocking | User-agents vides, methodes non-standard |
| Security headers | CSP, HSTS, X-Frame-Options, Referrer-Policy, Permissions-Policy |

## Auto-versioning

Les versions Nginx, ModSecurity et OWASP CRS sont resolues automatiquement au build time.
Pour forcer une version :

```bash
docker build \
  --build-arg NGINX_VER=1.30.2 \
  --build-arg MODSEC_VER=3.0.14 \
  --build-arg OWASP_CRS_VER=4.13.0 \
  .
```

## Usage rapide

```bash
cp .env.example .env
make build   # Build l'image
make up      # Demarre
make test    # Smoke tests (healthcheck + ModSec + blocked paths)
make scan    # Trivy vulnerability scan
make down    # Arrete
```

## Architecture

```
nginx-hardened/
├── Dockerfile              # 5-stage build (fetcher → builder → gobuilder → prep → scratch)
├── docker-compose.yml      # Stack hardenee
├── Makefile                # Raccourcis dev
├── versions.json           # Versions trackees (nginx, modsec, crs, alpine)
├── go.mod + init.go        # Go static init binary
├── conf/
│   ├── nginx/
│   │   ├── nginx.conf          # Config principale (hardened)
│   │   ├── conf.d/default.conf # Vhost par defaut
│   │   └── mime.types          # Types MIME
│   └── modsec/
│       ├── modsecurity.conf    # Config ModSecurity (blocking mode)
│       ├── main.conf           # Include principal
│       └── unicode.mapping     # Unicode normalization
├── errors/                 # Pages d'erreur custom (403, 404, 410, 5xx)
├── keys/                   # Cles GPG nginx embarquees
├── scripts/
│   ├── check-versions.sh  # Resolution auto des versions upstream
│   ├── deploy.sh          # Build/scan/sbom helper
│   └── test.sh            # Smoke tests
└── .github/workflows/
    ├── build-push.yml      # Build + sign + scan + release
    ├── version-watch.yml   # Daily upstream version detection
    └── security-audit.yml  # Weekly Trivy + Grype
```

## CI/CD

Dual pipeline (GitLab + GitHub Actions) :

| Stage | Description |
|-------|-------------|
| lint | hadolint |
| build | buildx + push (ghcr.io + Docker Hub) |
| sign | cosign keyless OIDC |
| scan | Trivy SARIF |
| attest | SBOM + SLSA provenance (level 2) |
| version-watch | Cron quotidien — rebuild auto sur nouvelle version Nginx/CRS |
| security-audit | Cron hebdomadaire — scan vulnerabilites sur images publiees |

## Monitoring

Module VTS sur `/vts-status` (restreint aux IPs privees via `allow`/`deny`).

## Security & Verification

This image is signed with [cosign](https://github.com/sigstore/cosign) using keyless OIDC (Sigstore).

### Verify image signature

```bash
# From ghcr.io (signatures stored natively)
cosign verify \
  --certificate-identity-regexp '^https://github.com/jbsky/nginx-hardened/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/jbsky/nginx-waf-hardened:latest

# From Docker Hub (signatures stored in ghcr.io)
COSIGN_REPOSITORY=ghcr.io/jbsky/nginx-waf-hardened \
  cosign verify \
  --certificate-identity-regexp '^https://github.com/jbsky/nginx-hardened/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/jbsky/nginx-waf-hardened:latest
```

### Hardening tier "Platine" guarantees

| Property | Description |
|----------|-------------|
| FROM scratch | No base image, no shell, no package manager |
| Go static init | Binary entrypoint + healthcheck (no script) |
| tini PID 1 | Proper signal forwarding and zombie reaping |
| Non-root | Runs as unprivileged UID |
| Compiler hardening | RELRO, PIE, SSP, FORTIFY_SOURCE, stack-clash, NX |
| Cosign signed | OIDC keyless signature via Sigstore transparency log |
| SBOM | Software Bill of Materials embedded in manifest |
| SLSA provenance | Build provenance attestation (level 2) |

## License

BSD-2-Clause (same as Nginx)
