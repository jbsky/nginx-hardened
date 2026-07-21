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
