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

**Important caveat, hit immediately on first run**: "keep the last 3 semver tags" is a
*generic hygiene* policy, not a CVE-aware one -- it has no idea which of those 3 is
still vulnerable. On GHCR, only 4 nginx versions had ever been tagged in total
(1.30.1-1.30.4), so "last 3" still included `1.30.2` (vulnerable) and only dropped
`1.30.1`. Caught by manually re-checking the post-run tag list, not by the script
itself; `1.30.2` was then deleted by hand (`gh api --method DELETE
/users/jbsky/packages/container/nginx-waf-hardened/versions/<id>`). **After any prune
run, cross-check the surviving semver tags against the CVE table above** -- if one
inside the keep-window is still flagged, delete it explicitly. Don't assume the
automated retention alone guarantees no vulnerable tag survives.

**Two script bugs found rolling this out fleet-wide (2026-07-21), fixed same day**:
this pattern was replicated across all `docker-hardened` repos, and the shared
`scripts/prune-registry-tags.sh`/`prune-ghcr-tags.sh` had two latent bugs that didn't
manifest here (nginx never exceeded 3 semver tags, and its `X.Y.Z` scheme dodged the
regex bug) but caused real damage on `squid-hardened` and `php-fpm-hardened`:

1. `sort -t. -k1,1n -k2,2n -k3,3n -r` does **not** reverse -- a trailing global `-r`
   after explicit numeric `-k` keys is silently ignored on GNU coreutils 9.7, so the
   "descending" sort was actually ascending. Consequence: the script deleted the
   *newest* semver tags instead of the oldest wherever tag count exceeded keep-count.
   On `php-fpm-hardened` this deleted `8.5.7` and `8.5.8` (the two current tags) while
   keeping `8.4.21`/`8.4.22`/`8.5.3` (the ones meant to be pruned). Fixed by putting
   `nr` directly on each `-k` (`-k1,1nr -k2,2nr -k3,3nr`) instead of a trailing `-r`.
2. The semver regex required exactly three dot-separated components (`X.Y.Z`), so a
   two-component scheme like `squid-hardened`'s `7.5`/`7.6` matched neither the
   "keep" branch nor the exclusion for `latest` -- it fell into "always delete"
   alongside `auto-*` snapshot tags, wiping out the *only* real version tags that
   existed. Fixed by widening the regex to `^[0-9]+(\.[0-9]+){1,2}$`.

A third, GHCR-specific gotcha compounded bug #2 on `squid-hardened`: GHCR groups
multiple tags that share a digest into a single "version" object, and
`prune-ghcr-tags.sh` classifies a version by its *first* tag only
(`.metadata.container.tags[0]`). When the doomed `7.6` tag happened to be listed
before `latest` on the same version object, deleting it deleted `latest` too --
disproving the assumption that "skip if tag == latest" is enough protection on GHCR
(it only protects a version whose first listed tag literally is `latest`).

Both `7.6` (squid-hardened) and `8.5.8`/`latest` (php-fpm-hardened, Docker Hub side
only -- GHCR stayed intact) were restored the same day via
`docker buildx imagetools create --tag <dst> <intact-source>`, copying the manifest
from whichever registry still had it rather than re-running a full build. `8.5.7` on
`php-fpm-hardened` is a permanent (harmless) loss -- an old, already-superseded tag.
**Lesson**: after writing a prune/delete script, dry-run the exact `sort`/regex logic
against real sample data (`printf ... | sort ...`) before trusting it against a live
registry -- a shellcheck pass and a clean YAML load say nothing about whether the
*logic* does what you meant.
