# Changelog

## v0.1.0 (in testing as v0.1.0-beta.N)

First version of the release flow.

- `gxp-candidate.yml`: release intake (framework version from OIDC, tag, initiator, impact assessment and its
  approval), unit tests with requirement traceability, single image build to GHCR, simulated staging with
  identity and smoke checks, evidence pack with SHA-256 list, release approval PR, superseding of older
  candidates.
- `gxp-promote.yml`: approval re-verification (candidate run, PR, reviews, verification record, evidence
  integrity), simulated production with the same digest, registry version tag, `vX.Y.Z` git tag and GitHub
  release with the release record.
- `framework-tests.yml`: actionlint and workflow step tests on every change and version tag.
- Design document with decision log.
