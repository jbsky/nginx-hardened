# Nginx WAF Hardened

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
