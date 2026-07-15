# Security Audit Status

The weekly `security-audit.yml` workflow (Trivy + Grype, `--fail-on high --only-fixed`)
scans the published image every Tuesday. This file tracks known, investigated
exceptions so the CI state doesn't need to be re-diagnosed from scratch each time it
comes up.

| CVE | Package | Status | Why | Resolves when |
|---|---|---|---|---|
| CVE-2026-42055 | nginx 1.30.3 | Suppressed (`.grype.yaml`) | Grype flags it against 1.30.3, but nginx's own [security advisories](https://nginx.org/en/security_advisories.html) explicitly state `Not vulnerable: 1.31.2+, 1.30.3+` -- 1.30.3 is already patched upstream. Confirmed false positive (likely stale/imprecise NVD range data), not a real gap. | N/A -- already fixed in the version shipped. Rule is locked to `nginx 1.30.3` and becomes inert automatically on any version bump. |
| CVE-2026-48142 | nginx 1.30.3 | Suppressed (`.grype.yaml`) | Same false positive, same advisory: `Not vulnerable: 1.31.2+, 1.30.3+`. | Same as above. |
