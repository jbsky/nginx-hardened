# Security Audit Status

The weekly `security-audit.yml` workflow (Trivy + Grype, `--fail-on high --only-fixed`)
scans the published image every Tuesday. This file tracks known, investigated
exceptions so the CI state doesn't need to be re-diagnosed from scratch each time it
comes up.

| CVE | Package | Status | Why | Resolves when |
|---|---|---|---|---|
| CVE-2026-42055 | nginx 1.30.3 | Suppressed (`.grype.yaml`) | Grype flags it against 1.30.3, but nginx's own [security advisories](https://nginx.org/en/security_advisories.html) explicitly state `Not vulnerable: 1.31.2+, 1.30.3+` -- 1.30.3 is already patched upstream. Confirmed false positive (likely stale/imprecise NVD range data), not a real gap. | N/A -- already fixed in the version shipped. Rule is locked to `nginx 1.30.3` and becomes inert automatically on any version bump. |
| CVE-2026-48142 | nginx 1.30.3 | Suppressed (`.grype.yaml`) | Same false positive, same advisory: `Not vulnerable: 1.31.2+, 1.30.3+`. | Same as above. |
| CVE-2026-42055 | nginx 1.30.4 | Suppressed (`.grype.yaml`) | Same false positive re-triggered after the Dockerfile's auto-latest `NGINX_VER` picked up 1.30.4. Still covered by `Not vulnerable: 1.30.3+`. | Same as above -- inert on next version bump. |
| CVE-2026-48142 | nginx 1.30.4 | Suppressed (`.grype.yaml`) | Same as above. | Same as above. |

## Recurring pattern: nginx patch bumps re-trip these CVEs

The Dockerfile fetches nginx via `NGINX_VER=""` (auto-detects latest stable at build
time), so the shipped nginx patch version drifts forward on its own. Since
`.grype.yaml` pins exceptions to an exact `version:`, every new nginx patch release
makes the existing suppression inert and the weekly audit fails again with the *same*
CVEs against the *new* version number -- this is by design, not a regression: it forces
a quick re-check against the nginx advisory rather than silently ignoring the CVE
forever. When this happens again: confirm the new version is still within
`Not vulnerable: 1.31.2+, 1.30.3+` on the advisory page above, add a new `ignore` entry
per CVE in `.grype.yaml` for that version, add a row here, and close the auto-filed
issue.

## Old vulnerable image tags left publicly pullable (found 2026-07-21, fixed)

`build-push.yml` and `version-watch.yml` both push the resolved nginx version as an
*immutable* tag (e.g. `1.30.4`) on every run, in addition to `:latest`, and never
retired the previous one. Over several months this left genuinely vulnerable versions
still live and pullable on both registries -- `1.30.1` and `1.30.2` were still on Docker
Hub/GHCR long after the CVE-2026-42055/48142 fix landed in `1.30.3` (NVD/F5 confirm
`1.30.2` itself sits inside the affected range: `version: 1.30.2, lessThan: 1.30.3,
status: affected`). Our own `security-audit.yml` never caught this because it only
scans `:latest` -- an external scanner walking the whole repo (e.g. Docker Hub's own
vulnerability scan) would flag it independently, which is how this was noticed.

Fixed by `registry-cleanup.yml` (`scripts/prune-registry-tags.sh` for Docker Hub,
`scripts/prune-ghcr-tags.sh` for GHCR), called as a job from both `build-push.yml` and
`version-watch.yml` after every push, and directly `workflow_dispatch`-able. Keeps the
last 3 semver tags + `:latest`, deletes older semver tags and all `auto-*` snapshot
tags (already preserved via git tags/GitHub Releases, never meant for pinning). Only
ever deletes a package version by its own named tag -- untagged manifest-list children,
attestations, and cosign signatures are left alone to avoid risking a still-live
manifest reference. `1.30.1`/`1.30.2` removed from both registries the same day.
