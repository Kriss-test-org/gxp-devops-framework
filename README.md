# GxP DevOps framework

Reusable GitHub workflows that take a web application from a release candidate tag to production through a
controlled, evidence-producing GxP release process: build once, verify on staging, approve, promote the same
image. See [docs/design.md](docs/design.md) for the design, controls and roadmap.

> **v0.1:** staging and production are simulated on the GitHub runner. Azure deployment arrives in v0.3.

## Using the framework in an application

Add two caller workflows to the application repository and pin a framework version:

```yaml
# .github/workflows/release-candidate.yml
name: GxP release candidate
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+-rc.[0-9]+']
permissions:
  contents: write
  packages: write
  pull-requests: write
  id-token: write
  actions: read
jobs:
  release:
    concurrency: { group: gxp-release-candidate, cancel-in-progress: false }
    uses: Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-candidate.yml@v0.1.0
    with:
      ui-expected-text: My App
```

```yaml
# .github/workflows/release-promote.yml
name: GxP production promotion
on:
  push:
    branches: [main]
    paths: ['validation/*/release-candidate.json']
permissions:
  contents: write
  packages: write
  pull-requests: read
  id-token: write
  actions: read
jobs:
  promote:
    concurrency: { group: gxp-promotion, cancel-in-progress: false }
    uses: Kriss-test-org/gxp-devops-framework/.github/workflows/gxp-promote.yml@v0.1.0
    with:
      ui-expected-text: My App
```

The application must also provide the items listed in
[design section 3](docs/design.md#what-an-application-must-provide): `/health`, `/version`, runtime
configuration, JUnit test results, `deploy/*.env`, `.gxp/roles.yml` and an impact assessment per release.
[gxp-demo-app](https://github.com/Kriss-test-org/gxp-demo-app) is a complete example.

### Inputs

| Workflow | Input | Default |
|---|---|---|
| candidate | `node-version` | `22` |
| candidate | `install-command` (empty to skip) | `npm ci` |
| candidate | `test-command` | `npm test` |
| candidate | `test-results-path` (JUnit XML) | `test-results` |
| candidate | `dockerfile` / `build-context` | `Dockerfile` / `.` |
| candidate | `staging-config` / `production-config` | `deploy/staging.env` / `deploy/production.env` |
| both | `container-port` | `8080` |
| both | `ui-expected-text` (empty to skip) | |

## One-time settings

| Where | Setting |
|---|---|
| This repository → Settings → Actions → General → **Access** | *Accessible from repositories in the organization* |
| Organization → Settings → Actions → General → **Workflow permissions** | Tick *Allow GitHub Actions to create and approve pull requests* |
| Application repository → Settings → Actions → General → **Workflow permissions** | Tick *Allow GitHub Actions to create and approve pull requests* |

Container images go to GitHub Container Registry (`ghcr.io/<org>/<repo>`); the first build creates the package.

## Versioning

Releases are tags `vMAJOR.MINOR.PATCH`. Applications must reference a tag; the framework refuses branch
references. Pre-release tags such as `v0.1.0-beta.1` work for testing and are marked "not for GxP use" in every
record. Changes are listed in [CHANGELOG.md](CHANGELOG.md).
