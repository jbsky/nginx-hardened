# Nginx WAF Hardened

[![Build](https://github.com/jbsky/nginx-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/nginx-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/nginx-waf-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/nginx-waf-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/nginx-hardened#security--verification)

Image Docker Nginx compilee from source avec :

- **ModSecurity v3** — WAF en mode blocking
- **OWASP Core Rule Set** — dernieres regles de securite
- **GeoIP2** — blocage geographique (db-ip free)
- **VTS** — monitoring trafic (`/vts-status`)
- **headers-more** — controle complet des headers HTTP

## Auto-versioning

Les versions sont automatiquement resolues au build time.
Pour forcer une version :

```bash
docker build \
  --build-arg NGINX_VER=1.27.4 \
  --build-arg MODSEC_VER=3.0.14 \
  --build-arg OWASP_CRS_VER=4.13.0 \
  .
```

## Hardening

- Compilation avec `-fstack-protector-strong -fPIE -D_FORTIFY_SOURCE=2` + RELRO+NOW
- GPG verification du tarball nginx
- Execution non-root (uid 1999)
- ModSecurity en mode **blocking**
- Security headers complets (CSP, HSTS, X-Frame-Options, Referrer-Policy, Permissions-Policy)
- Rate limiting + connection limiting
- Blocage bots, user-agents vides, methodes non-standard
- Timeouts anti-slowloris
- Modules inutiles desactives a la compilation
- Binaires strippes
- Healthcheck integre
- `server_tokens off` + `more_clear_headers Server`

## Usage rapide

```bash
make build   # Build l'image
make up      # Demarre
make test    # Smoke tests (healthcheck + ModSec + blocked paths)
make scan    # Trivy scan
make down    # Arrete
```

## CI/CD

Le repo est compilable sur **GitLab** et **GitHub** :

| Plateforme | Pipeline |
|-----------|----------|
| GitLab | lint → build → sign (cosign OIDC) → scan (Trivy SARIF) → release |
| GitHub | lint → build → sign (cosign OIDC) → scan (Trivy) → attestation SLSA → release |

Rebuild hebdomadaire automatique pour capter les nouvelles versions upstream.

## Monitoring

Module VTS sur `/vts-status` (restreint aux IPs privees).

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
