# GxP DevOps framework

Reusable GitHub workflows that take a change from a free-text request to production through a controlled,
evidence-producing GxP process: approve the request, review the code, build once, verify on staging, approve,
promote the same image. Each release candidate is **one workflow run**, so the run page shows every step: what
passed, what is waiting for whom, and what is still to come. See [docs/design.md](docs/design.md) for the
design, controls and roadmap.

> **v0.2:** staging and production are simulated on the GitHub runner. Azure deployment arrives in v0.3.

## The flow

1. **Request:** anyone opens an issue in free text.
2. **Approval:** a change approver comments on it:
   ```
   /approve
   impact: low             none | low | medium | high
   path: targeted          abbreviated | targeted | full  (high needs full, medium targeted or full)
   type: feature           fix | feature | breaking       (decides the next version)
   requirements: URS-005, URS-001
   reason: Display-only change; the evaluation is unchanged.
   cc: CC-1234             optional eQMS reference
   ```
3. **Development** on `develop` (Lovable).
4. **Pull request** `develop` → `stage` with `Closes #<issue>`, reviewed by a change approver who did not write
   the code, then merged. The merge starts the release run:

| Job | Waits for | Does |
|---|---|---|
| 1 · Release intake | | Change requests and pull requests in the candidate, all rules, version, gate setup |
| 2 · Unit tests | | Runs the tests, summarises them per requirement ID |
| 3 · Build image (once) | | Builds and pushes one image, records its digest |
| 4 · Staging deployment and automated checks | | Runs the digest on staging, checks it; cancels superseded runs |
| 5 · Evidence pack | | Release candidate record and all evidence with SHA-256 list |
| 6 · Verification | a verifier (`gxp-verification`) | Checks the verifier and the `PASS <reference>` comment |
| 7 · Promote to production | a release approver (`gxp-production`) | Checks separation of duties, deploys the same digest, checks it |
| 8 · Release | | Moves `main`, tags `vX.Y.Z`, GitHub release with PDF report, closes the change requests |

If a gate fails (for example the approval comment was missing), use **Re-run failed jobs**: the gate waits
again and the newest approval counts. Do not use *Re-run all jobs*; the build refuses to build the same
candidate twice.

## Using the framework in an application

Two caller workflows, pinned to a framework version:

```yaml
# .github/workflows/release.yml
name: GxP release
run-name: GxP release candidate ${{ github.run_number }}
on:
  push:
    branches: [stage]
permissions:
  contents: write
  packages: write
  pull-requests: read
  issues: write
  deployments: read
  id-token: write
  actions: write
jobs:
  release:
    name: Release
    uses: Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-release.yml@v0.2.0
    with:
      ui-expected-text: My App
```

```yaml
# .github/workflows/change-requests.yml
name: GxP change requests
on:
  issues:
    types: [opened, edited]
  issue_comment:
    types: [created]
permissions:
  contents: read
  issues: write
jobs:
  change-request:
    name: Change request
    if: ${{ !github.event.issue.pull_request }}
    uses: Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-change-request.yml@v0.2.0
```

The application also provides the items in
[design section 3](docs/design.md#what-an-application-must-provide), including `.gxp/roles.yml`:

```yaml
schema: gxp-roles/v2
change_approvers: [it-person]        # /approve change requests, review pull requests
verifiers: [business-person]         # approve gxp-verification
release_approvers: [it-person]       # approve gxp-production
```

[gxp-demo-app](https://github.com/Kriss-test-org/gxp-demo-app) is a complete example.

### Inputs of `gxp-release.yml`

| Input | Default |
|---|---|
| `stage-branch` / `production-branch` | `stage` / `main` |
| `node-version` | `22` |
| `install-command` (empty to skip) | `npm ci` |
| `test-command` | `npm test` |
| `test-results-path` (JUnit XML) | `test-results` |
| `dockerfile` / `build-context` | `Dockerfile` / `.` |
| `staging-config` / `production-config` | `deploy/staging.env` / `deploy/production.env` |
| `container-port` | `8080` |
| `ui-expected-text` (empty to skip) | |

## One-time setup in the application repository

1. **Branches:** create `stage` and `develop` from `main`. Workflow and role changes made on `main` before
   this point are the setup; afterwards everything goes `develop` → `stage` → `main`.
2. **Environments** (Settings → Environments → New environment):

   | Environment | Required reviewers | Prevent self-review |
   |---|---|---|
   | `gxp-verification` | The verifiers | Off |
   | `gxp-production` | The release approvers | **On** |

   In both, untick *Allow administrators to bypass configured protection rules*. `gxp-staging` is created on
   the first run.

Required reviewers on private repositories need GitHub Enterprise. Container images go to GitHub Container
Registry (`ghcr.io/<org>/<repo>`).

## Testing the framework

[framework-tests.yml](.github/workflows/framework-tests.yml) runs on every change and every version tag:

- **Lint workflows:** actionlint, including shellcheck on every script step.
- **Workflow step tests:** [tests/workflow-steps.sh](tests/workflow-steps.sh) runs the script steps with test
  inputs, including every intake rule (unlinked commits, unreviewed or self-reviewed code, unapproved,
  self-approved, edited or rejected change requests, invalid assessments, version calculation).
- **Release tag check:** release tags must be lightweight.

Steps that depend on GitHub itself (API calls, approvals, OIDC, cross-repository calls, registry) are tested
end to end with [gxp-demo-app](https://github.com/Kriss-test-org/gxp-demo-app).

## Versioning

Releases are lightweight tags `vMAJOR.MINOR.PATCH` (`git tag v1.2.0 <commit>`, no `-a`). Applications must
reference a tag; the framework refuses branch references. Pre-release tags such as `v0.2.0-beta.1` work for
testing and are marked "not for GxP use" in every record. Changes are listed in [CHANGELOG.md](CHANGELOG.md).
