# CI/CD reference

Patterns and templates for `/magi:web-ci-spec`. Read once before
elaborating a feature's pipeline / deployment story.

## Discovery

| Signal | Likely CI/CD |
|--------|---------------|
| `.github/workflows/*.yml` | GitHub Actions |
| `cloudbuild.yaml`, `cloudbuild/*.yaml` | Google Cloud Build |
| `.gitlab-ci.yml` | GitLab CI |
| `azure-pipelines.yml` | Azure DevOps |
| `bitbucket-pipelines.yml` | Bitbucket Pipelines |
| `Jenkinsfile` | Jenkins |
| `wrangler.toml` + `cloudflare/` | Cloudflare Pages/Workers |
| `vercel.json` | Vercel |

For mixed setups (e.g. GHA for tests + Cloud Build for prod deploys), document the boundary clearly.

## Pipeline stages — minimum viable shape

For any non-trivial change, the spec must define stages and what runs in each:

```
on:    push (PR-targeted), pull_request, manual (workflow_dispatch)
       schedule (for canary / dependency refresh)
       tag push (for releases)

stages:
  1. preflight    — checkout, setup language runtime, restore caches
  2. static       — lint, format check, type check, secrets scan
  3. test         — unit, component, integration; emit coverage
  4. build        — produce artifacts (docker, bundle, binaries); SBOM
  5. e2e          — Playwright / Cypress against an ephemeral env
  6. security     — SCA (npm audit / pip audit / cargo audit), container scan, IaC scan
  7. publish      — push image / tag artifact (only on main / tag)
  8. deploy       — staging on merge; prod on tag with manual approval
  9. smoke        — post-deploy health check, rollback trigger
```

Not all stages apply to every project — but justify any omission.

## Secrets handling — non-negotiable section

Every pipeline change must answer:

- **Where do secrets live?** GitHub Actions secrets / GCP Secret Manager (via WIF) / HashiCorp Vault / Cloud Build substitutions backed by Secret Manager.
- **Workload Identity Federation (WIF)** — preferred over long-lived service account keys for cross-cloud auth. If a key file is being added, push back hard.
- **Scope** — is the secret available at every step, or only the publish/deploy ones? Default: tightest scope.
- **Rotation** — how is this secret rotated? Who owns rotation?
- **Audit** — is there a CI log that masks the secret correctly? (`***`)

Forbidden:

- ❌ `echo $SECRET >> $GITHUB_ENV` (leaks via logs).
- ❌ Committing `.env.*` files with real values.
- ❌ Service account JSON keys in repo or Secret Manager when WIF is available.
- ❌ Using PAT in a workflow that runs on PRs from forks (compromise vector).

## Permissions hygiene

- **Token scope**: `permissions:` block in GHA workflows — set to least privilege (`contents: read` by default; raise per-job).
- **OIDC**: `id-token: write` only on jobs that need to mint short-lived cloud creds.
- **PR from fork**: `pull_request_target` is dangerous; treat any code from forked PR as untrusted.
- **Reusable workflows**: pin to SHA (`@<sha>`), not `@v1`, for any third-party action that handles secrets.

## Caching strategy

- Lockfile-based cache keys (e.g. `hashFiles('**/pnpm-lock.yaml')`).
- Layer caching for Docker (`buildx` with `cache-from`/`cache-to`).
- Test-runner caches (Vitest's `--cache`, jest's `--cache`).
- Don't share caches between languages / environments — `${{ matrix.os }}-${{ matrix.node }}-...`.

Document cache TTL / size budget if the project has hit GitHub's 10 GB cap.

## Deployment strategy

For every deploy stage:

- **Target environment** — staging / canary / prod; one Cloud Run service, or many?
- **Strategy** — rolling, blue-green, canary; what % cuts to next ring?
- **Approval gate** — auto on `main`, manual via environment protection rules for prod.
- **Rollback trigger** — automated on smoke failure, or manual? Time budget.
- **Database migrations** — run before / after deploy? Backfill window? Forward/back compatibility window of N versions.
- **Feature flags** — does the change ride a flag? Default off in prod, ramp manually.

## Smoke tests post-deploy

Required for any deploy to a shared env:

```yaml
- name: Smoke test (staging)
  run: |
    set -euo pipefail
    BASE_URL=https://staging.example.com
    # Health endpoint
    curl -fsS "$BASE_URL/healthz" | jq -e '.status == "ok"'
    # Critical user path
    curl -fsS "$BASE_URL/api/v1/users/me" \
      -H "Authorization: Bearer $SMOKE_TOKEN" \
      | jq -e '.id'
```

If smoke fails: the workflow should fail loudly AND trigger rollback (manual or automated).

## Observability for the pipeline itself

- Enable workflow run summaries (`$GITHUB_STEP_SUMMARY` / Cloud Build logs link) so reviewers can read the verdict without clicking through.
- Slack / Chat notifications on red main — not on every PR.
- Track DORA metrics if the org cares: deploy frequency, lead time, change failure rate, MTTR.

## Test plan for the pipeline change itself

- Run the workflow in a draft PR before merging.
- Use `act` (https://github.com/nektos/act) to simulate locally for GHA.
- For Cloud Build: `gcloud builds submit --config=cloudbuild.yaml --no-source` against a known-good source ref.
- Diff the rendered config (`gh workflow view <id>` or `gcloud builds describe <id>`) against the previous version.

## Common anti-patterns to flag

- ❌ A single workflow doing everything (split by trigger / concern).
- ❌ Using `actions/checkout@master` (mutable) instead of pinned SHA.
- ❌ Running `npm install` instead of `npm ci` (or pnpm/yarn equivalent).
- ❌ Skipping cache because "it's flaky" — fix the cache key, don't drop it.
- ❌ Using `if: failure()` to swallow failures instead of fixing them.
- ❌ Running tests in the same job as deploy — separate concerns, separate retries.
- ❌ Running secrets scan only on PR — also on `main` push, in case secrets sneak in.
- ❌ Building images on every PR push without buildx caching.

## Templates

### GHA workflow skeleton

```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  static:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-node@<sha>
        with:
          node-version-file: .nvmrc
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - run: pnpm lint
      - run: pnpm typecheck

  test:
    runs-on: ubuntu-latest
    needs: static
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-node@<sha>
        with: { node-version-file: .nvmrc, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm test --coverage
      - uses: actions/upload-artifact@<sha>
        with: { name: coverage, path: coverage/ }

  e2e:
    runs-on: ubuntu-latest
    needs: test
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/setup-node@<sha>
        with: { node-version-file: .nvmrc, cache: pnpm }
      - run: pnpm install --frozen-lockfile
      - run: pnpm exec playwright install --with-deps chromium
      - run: pnpm e2e
      - uses: actions/upload-artifact@<sha>
        if: always()
        with: { name: playwright-report, path: playwright-report/ }
```

### Cloud Build skeleton (deploy via WIF)

```yaml
# cloudbuild-deploy.yaml
steps:
  - id: lint
    name: gcr.io/cloud-builders/npm
    entrypoint: bash
    args: [-c, "npm ci && npm run lint"]

  - id: test
    name: gcr.io/cloud-builders/npm
    entrypoint: bash
    args: [-c, "npm test -- --coverage"]

  - id: build-image
    name: gcr.io/cloud-builders/docker
    args: ["build", "-t", "${_IMAGE}:${SHORT_SHA}", "."]

  - id: push-image
    name: gcr.io/cloud-builders/docker
    args: ["push", "${_IMAGE}:${SHORT_SHA}"]

  - id: deploy
    name: gcr.io/google.com/cloudsdktool/cloud-sdk
    entrypoint: gcloud
    args:
      - run
      - deploy
      - ${_SERVICE}
      - --image=${_IMAGE}:${SHORT_SHA}
      - --region=${_REGION}
      - --no-traffic         # canary
      - --tag=canary

  - id: smoke
    name: gcr.io/cloud-builders/curl
    args: ["-fsS", "https://${_REGION}-${PROJECT_ID}.run.app/healthz"]

substitutions:
  _SERVICE: my-app
  _REGION: asia-east1
  _IMAGE: ${_REGION}-docker.pkg.dev/${PROJECT_ID}/${_SERVICE}/${_SERVICE}

options:
  logging: CLOUD_LOGGING_ONLY
  pool:
    name: projects/${PROJECT_ID}/locations/${_REGION}/workerPools/default

# WIF-based identity, no key file
serviceAccount: projects/${PROJECT_ID}/serviceAccounts/cloud-build-runner@${PROJECT_ID}.iam.gserviceaccount.com
```

## Deliverable

`/magi:web-ci-spec` produces a sprint file `magi/<num>-<slug>/CI.md`:

```markdown
# CI/CD plan — <feature name>

## Summary
<what's changing in the pipeline and why>

## Triggers
<on push / PR / schedule / tag>

## Stages & jobs
<table or list>

## Secrets & permissions
- Secrets used: ...
- Workload identity: ...
- Token scope per job: ...

## Caching
<keys + size budget>

## Deployment strategy
- Targets: ...
- Rollout: ...
- Approval gate: ...
- Rollback: ...

## Smoke tests
<commands + acceptance criteria>

## Observability
<summaries, notifications, dashboards>

## Test plan for the workflow itself
<draft PR / act / Cloud Build dry-run>

## Open questions
- ...
```

Plus the rendered workflow file (`.github/workflows/<name>.yml` or
`cloudbuild*.yaml`) — but only as a draft. The user reviews before commit.
