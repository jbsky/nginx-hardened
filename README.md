# Nginx WAF Hardened

[![Build](https://github.com/jbsky/nginx-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/nginx-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/nginx-waf-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/nginx-waf-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/nginx-hardened#hardening)

nginx <!--v:nginx-waf-hardened-->1.30.6<!--/v--> built from source with the ModSecurity WAF and
the OWASP Core Rule Set, in a `FROM scratch` image: no shell, no package
manager, no OS. Only nginx, its modules, their libraries, `tini` and a static
Go init. Published as `jbsky/nginx-waf-hardened`.

## What is built

| Module | Role |
|---|---|
| ModSecurity v3 | WAF in blocking mode |
| OWASP Core Rule Set | WAF rules |
| GeoIP2 | country blocking (db-ip lite database) |
| VTS | traffic monitoring (`/vts-status`) |
| headers-more | full control of HTTP headers |

- **nginx**: release tarball verified against the nginx signing keys
  committed in [`keys/`](keys). Built without autoindex, SSI or the mail
  modules.
- **ModSecurity and the CRS**: cloned at the release tag pinned in
  [`versions.json`](versions.json). Their versions are deliberately not quoted
  in this README: CI renders only the nginx version, and a value that is
  neither resolved nor rendered drifts silently.
- **The four nginx modules** (ModSecurity connector, GeoIP2, VTS,
  headers-more) are built from the head of their upstream `master` branch, not
  from a pinned version.
- **GeoIP**: only the db-ip country lite database is downloaded at build time
  (the city database, never read by the configuration, is not shipped).
- Custom error pages in [`errors/`](errors) (403, 404, 410, 5xx, maintenance).

## Hardening

Tier **platine** (OCI label `security.hardening.tier`): a `FROM scratch` image
with no shell and no package manager, a non-root user, a static Go init behind
`tini` as PID 1, and binaries built with hardening flags.

- Non-root user `1999:1999`; tested under a read-only rootfs, `cap_drop: ALL`
  (plus `NET_BIND_SERVICE`) and `no-new-privileges`.
- Compiler flags: PIE, full RELRO, `-fstack-protector-strong`,
  `-fstack-clash-protection`, `_FORTIFY_SOURCE=2`, non-executable stack.
- Libraries copied from a dependency closure resolved at build time
  (`lddtree`), never `/lib` or `/usr/lib` wholesale.
- The init validates the configuration (`nginx -t`) before starting.
- Shipped configuration ([`conf/`](conf)):
  - ModSecurity in blocking mode, not detection only;
  - `server_tokens off`;
  - rate and connection limiting per client, aggressive client timeouts
    (slowloris);
  - empty user agents and non-standard methods refused;
  - security headers: CSP, HSTS, `X-Frame-Options`, `Referrer-Policy`,
    `Permissions-Policy`.

## Tags

Every image is published under three tags: `latest` (last build of `main`),
the upstream version alone, and the upstream version followed by a **revision
counter**. The first two are **overwritten in place** on every rebuild (Alpine
update, CVE fix, configuration change), and the build they pointed to can no
longer be pulled by them. **In production, pin the tag that carries the
counter.**

<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->
| Image | Version amont | Tag immuable a epingler |
|-------|---------------|-------------------------|
| `jbsky/nginx-waf-hardened` | `1.30.6` | `1.30.6.35` |
<!-- END:tags -->

This table, the versions quoted in the text and the tags in the examples are
rendered by `update-readme-tags.sh` ([hardened-ci](https://github.com/jbsky/hardened-ci))
after each publication: do not edit them by hand.

The counter counts the commits that touch the image inputs (the `revision`
list of [`.github/hardened-ci.json`](.github/hardened-ci.json)). A commit that
only touches `.github/` does not increment it. Unlike the other images of the
fleet, it **does not restart at `0`** with each new nginx version: it counts
from the repository's first commit (`--unanchored`), a leftover from the time
the nginx, ModSecurity and CRS versions were resolved at build time instead of
being pinned in `versions.json`. Tags stay unique, because the version prefix
changes with each release.

`docker.io` and `ghcr.io` publish the same tags with the same digest, for
`linux/amd64` and `linux/arm64`. Each registry keeps the last six immutable
tags of an image, so that superseded builds do not stay pullable: move your
pin forward.

`version-watch` checks nginx, ModSecurity and the CRS daily, bumps
`versions.json` and republishes: since `versions.json` is a revision input,
each bump yields a new immutable tag, and a tag always names the same image.

## Usage

```bash
docker run -d --name nginx-waf \
  --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=64m,mode=1777,nodev,nosuid,noexec \
  --tmpfs /var/run/nginx:size=1m,mode=0755,uid=1999,gid=1999 \
  --tmpfs /var/cache/nginx:size=128m,mode=0755,uid=1999,gid=1999 \
  -v ./conf.d:/etc/nginx/conf.d:ro \
  -v html:/var/www/html \
  -p 80:80 -p 443:443 \
  jbsky/nginx-waf-hardened:1.30.6.35
```

- Virtual hosts go in `/etc/nginx/conf.d/`; the shipped
  [`default.conf`](conf/nginx/conf.d/default.conf) shows the WAF, GeoIP and
  rate-limit wiring.
- **Healthcheck**: `GET http://127.0.0.1:80/healthz`, answered by the shipped
  configuration.
- **Monitoring**: the VTS module on `/vts-status`, restricted to private
  addresses (`allow`/`deny`).

### Configuration

| Environment variable | Default | Description |
|---|---|---|
| `NGINX_CONF` | `/etc/nginx/nginx.conf` | File validated with `nginx -t` before start |

## Build and test

```bash
cp .env.example .env
make build   # build args come from versions.json
make up      # start the compose stack
make test    # scripts/test.sh against the running container
make scan    # Trivy
```

`scripts/test.sh` checks the healthcheck, that dotfiles, `.git`, SQL dumps and
`wp-login.php` are refused, that `TRACE` is refused, and that ModSecurity
blocks a SQL injection and an XSS.

Versions live only in [`versions.json`](versions.json): the Dockerfile has no
defaults, `make build` and CI pass them through `scripts/versions-build-args.py`,
and a bare `docker build` stops at the guard. To try another version, change
it in `versions.json`, never on the command line:

```bash
docker build $(scripts/versions-build-args.py --docker) .
```

## Verification

Images are signed with [cosign](https://github.com/sigstore/cosign) (keyless,
GitHub OIDC) by the shared [hardened-ci](https://github.com/jbsky/hardened-ci)
pipeline. The certificate names that workflow and, in an extension, this
repository: the commands below require both.

```bash
# ghcr.io
cosign verify ghcr.io/jbsky/nginx-waf-hardened:1.30.6.35 \
  --certificate-identity-regexp '^https://github.com/(jbsky/nginx-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/nginx-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Docker Hub (the signature is stored on ghcr.io)
COSIGN_REPOSITORY=ghcr.io/jbsky/nginx-waf-hardened \
  cosign verify docker.io/jbsky/nginx-waf-hardened:1.30.6.35 \
  --certificate-identity-regexp '^https://github.com/(jbsky/nginx-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/nginx-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Each published digest also carries a CycloneDX SBOM (the `prep` stage the
image is assembled from, plus its Go binaries), attested with cosign, and a
GitHub SLSA build provenance attestation. The pipeline lints, builds, scans the
`prep` stage with Trivy, tests the exact digest it is about to publish (image
manifest, dependency closure, functional tests), then promotes and signs it.
Base image digests follow upstream daily (`base-watch`), a fixable Alpine
package CVE triggers a rebuild (`cve-watch`), and the published image is
audited weekly (`security-audit`: Trivy, Grype, cosign). Audit status and
documented exceptions: [`SECURITY.md`](SECURITY.md).

## License

The contents of this repository (Dockerfile, `init.go`, scripts and CI) are
licensed under **Apache-2.0**, see [`LICENSE`](LICENSE). Copyright 2026 jbsky.

The software shipped in the image keeps its own license: **nginx is under
BSD-2-Clause**, and ModSecurity, the OWASP Core Rule Set and the modules keep
their upstream's. The two never mix: `init.go` is a separate program that
executes nginx without being linked to its libraries.

Contributions: see [`CONTRIBUTING.md`](CONTRIBUTING.md); a `Signed-off-by` is
required.
