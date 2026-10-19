# GxP DevOps framework

A reusable GitHub workflow that takes a web application from a release candidate tag to production through a
controlled, evidence-producing GxP release: build once, verify on staging, approve, promote the same image.
Each release is **one workflow run**, so the run page shows every step: what passed, what is waiting for whom,
and what is still to come. See [docs/design.md](docs/design.md) for the design, controls and roadmap.

> **v0.1:** staging and production are simulated on the GitHub runner. Azure deployment arrives in v0.3.

## The release run

| Job | Waits for | Does |
|---|---|---|
| 1 · Release intake | | Framework version, tag, initiator, impact assessment and its approval, gate setup |
| 2 · Unit tests | | Runs the tests, summarises them per requirement ID |
| 3 · Build image (once) | | Builds and pushes one image, records its digest |
| 4 · Staging deployment and automated checks | | Runs the digest on staging, checks identity, health, `/version`, home page; cancels superseded runs |
| 5 · Evidence pack | | Release candidate record and all evidence with SHA-256 list |
| 6 · Verification | a verifier (`gxp-verification`) | Checks the verifier and the `PASS <reference>` comment |
| 7 · Promote to production | an approver (`gxp-production`) | Checks the approver is neither initiator nor verifier, deploys the same digest, checks it, tags the image |
| 8 · Record the release | | Git tag `vX.Y.Z`, GitHub release with a PDF release report, the release record and the evidence |

If a gate fails (for example the approval comment was missing), use **Re-run failed jobs**: the gate waits
again and the newest approval counts. Do not use *Re-run all jobs*; the build refuses to build the same
candidate twice.

## Using the framework in an application

Add one caller workflow and pin a framework version:

```yaml
# .github/workflows/release.yml
name: GxP release
run-name: GxP release ${{ github.ref_name }}
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+-rc.[0-9]+']
permissions:
  contents: write
  packages: write
  pull-requests: read
  deployments: read
  id-token: write
  actions: write
jobs:
  release:
    name: Release
    uses: Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-release.yml@v0.1.0
    with:
      ui-expected-text: My App
```

The application must also provide the items in
[design section 3](docs/design.md#what-an-application-must-provide): `/health`, `/version`, runtime
configuration, JUnit test results, `deploy/*.env`, `.gxp/roles.yml` and an impact assessment per release.
[gxp-demo-app](https://github.com/Kriss-test-org/gxp-demo-app) is a complete example.

### Inputs

| Input | Default |
|---|---|
| `node-version` | `22` |
| `install-command` (empty to skip) | `npm ci` |
| `test-command` | `npm test` |
| `test-results-path` (JUnit XML) | `test-results` |
| `dockerfile` / `build-context` | `Dockerfile` / `.` |
| `staging-config` / `production-config` | `deploy/staging.env` / `deploy/production.env` |
| `container-port` | `8080` |
| `ui-expected-text` (empty to skip) | |

## One-time setup in the application repository

Settings → Environments → **New environment**:

| Environment | Required reviewers | Prevent self-review |
|---|---|---|
| `gxp-verification` | The verifiers | Off (the person who starts a release may verify it) |
| `gxp-production` | The approvers | **On** (the person who starts a release cannot approve it) |

In both, untick *Allow administrators to bypass configured protection rules*. A bypass leaves no approval
behind, so the gate job would fail anyway; the intake warns about it early.

`gxp-staging` is created automatically on the first run. The intake job fails if the two gated environments
are missing or misconfigured, and the gates check the recorded approval against `.gxp/roles.yml` again.

Required reviewers on private repositories need GitHub Enterprise. Container images go to GitHub Container
Registry (`ghcr.io/<org>/<repo>`); the first build creates the package.

## Testing the framework

[framework-tests.yml](.github/workflows/framework-tests.yml) runs on every change and every version tag:

- **Lint workflows:** actionlint, including shellcheck on every script step.
- **Workflow step tests:** [tests/workflow-steps.sh](tests/workflow-steps.sh) runs the script steps with test
  inputs and checks they accept valid input and reject what they must block.

Steps that depend on GitHub itself (API calls, approvals, OIDC, cross-repository calls, registry) are tested
end to end with [gxp-demo-app](https://github.com/Kriss-test-org/gxp-demo-app).

## Versioning

Releases are tags `vMAJOR.MINOR.PATCH`. Applications must reference a tag; the framework refuses branch
references. Pre-release tags such as `v0.1.0-beta.3` work for testing and are marked "not for GxP use" in every
record. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

Release tags must be lightweight (`git tag v1.2.0 <commit>`, no `-a`). For annotated tags, GitHub reports the
tag object instead of the commit, and release records would not identify the framework commit. The framework
tests fail on an annotated release tag.
