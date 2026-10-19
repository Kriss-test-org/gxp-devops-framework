# Changelog

## v0.1.0 (in testing as v0.1.0-beta.N)

First version of the release flow, as one workflow run per release candidate.

- `gxp-release.yml`:
  - Release intake: framework version from OIDC, tag, initiator, impact assessment and its PR approval,
    check that the release gates are set up.
  - Unit tests with requirement traceability.
  - Single image build to GHCR with registry digest check.
  - Simulated staging (`gxp-staging` environment) with identity and smoke checks; cancels superseded runs.
  - Evidence pack with SHA-256 list.
  - Verification gate (`gxp-verification`) and production approval gate (`gxp-production`), both re-checked
    against `.gxp/roles.yml` and separation of duties.
  - Simulated production with the same digest, registry version tag, `vX.Y.Z` git tag and GitHub release with
    the release record.
- `framework-tests.yml`: actionlint and workflow step tests on every change and version tag.
- Design document with decision log.

### beta.3

- PDF release report (`release-report-vX.Y.Z.pdf`) attached to every release and included in `SHA256SUMS`:
  release, change control, decisions and responsibilities, stage timeline, unit tests with requirement
  traceability, staging and production checks, configuration and evidence hashes.
- Gates can be retried with *Re-run failed jobs*; the newest approval counts (GitHub lists approvals newest
  first). Evidence uploads overwrite on re-runs.
- Intake warns when a gate environment lets administrators bypass its reviewers.
- Runners pinned to `ubuntu-24.04` instead of `ubuntu-latest`.
- Framework tests fail on annotated release tags, so release records identify the framework commit.

### beta.2

- Replaced the two workflows and the PR-based release approval of beta.1 with a single run and environment
  gates, so the whole release is visible in one place (decision D-03).
