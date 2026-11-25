# Security policy

VoxoL is pre-release software. Do not use it for sensitive dictation until the relevant phase
gates and threat-model tests pass.

## Reporting a vulnerability

Open an issue at <https://github.com/aristocratte/VoxoL/issues>. Issues are public, so describe
the problem without transcripts, audio, credentials or private context.

## Distribution

Current builds are signed with an Apple Development certificate and are not notarized, so macOS
Gatekeeper treats them as unverified software. `.github/workflows/release.yml` describes
Developer ID signing, notarization and stapling; it has not produced a release yet because the
certificate is missing.

The built-in updater downloads the disk image of the GitHub release you accept, then checks that
the application inside has the same bundle identifier as the running app, the same signing team
(when the running app has one), a passing `codesign --verify --deep`, and a version that is newer
than the running app and equal to the announced release. It does not run `spctl` and does not
compare the download with a published SHA-256. After the checks it removes the quarantine
attribute from the staged copy.

## Models

Every model artifact is pinned to a repository revision and checked by size and SHA-256 before it
is activated. The metrics log holds no words; the diagnostics log described in `PRIVACY.md`
quotes the words the recogniser doubted. Deterministic output stays available whenever model
output is rejected.
