# Changelog

## v0.2.0 (in testing as v0.2.0-beta.N)

From change request to production.

- `gxp-change-request.yml` (new): issues are free-text change requests. `/approve` with impact, path, type,
  requirements, reason (and optional `cc`) or `/reject`; validation feedback, labels `cr:new`, `cr:approved`,
  `cr:changed`, `cr:rejected`; editing an approved request withdraws the approval label.
- `gxp-release.yml`:
  - Starts on a push to `stage` (a merged pull request from `develop`) instead of a release candidate tag.
  - Intake collects the commits not yet on `main`, their pull requests and the referenced change requests, and
    enforces: every commit via a merged PR, every PR reviewed by a change approver who did not write it and
    linked to a change request, every change request validly approved (not by the requester, not edited,
    not rejected).
  - Version generated from the previous release and the change request types; candidate label `X.Y.Z-rc.N`.
  - Roles schema `gxp-roles/v2` (`change_approvers`, `verifiers`, `release_approvers`), read from `main`.
  - Production approver must be neither a code author nor the verifier.
  - Release job moves `main` (fast-forward) to the validated commit, tags `vX.Y.Z`, publishes the release and
    closes the change requests with `cr:released`.
  - Release record and PDF report list the change requests, pull requests, reviews and code authors.
- Impact assessment files and release candidate tags are no longer used.

### beta.2

- A pull request that references a deleted or non-existent issue is reported clearly ("#2, referenced by
  PR #3, does not exist") instead of failing with a GraphQL error.
- A code review only counts if it was submitted before the pull request was merged.
- Jobs 7 and 8 have fixed names, so skipped jobs no longer show an unresolved expression.

## v0.1.0 (not released; superseded by v0.2.0)

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
