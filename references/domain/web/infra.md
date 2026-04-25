# Infrastructure reference

Patterns and templates for `/maestro.web.infra.plan`. Read once before
elaborating a feature's infra section. Bias: **gcloud + Terraform** because
the user runs primarily on GCP, but principles transfer to AWS / Azure.

## Discovery

| Signal | Likely IaC |
|--------|------------|
| `*.tf`, `*.tf.json`, `terraform/` directory | Terraform |
| `pulumi.yaml` | Pulumi |
| `cloudformation/`, `*.yaml` with `AWSTemplateFormatVersion` | CloudFormation |
| `serverless.yml` | Serverless Framework |
| `cdk.json` | AWS CDK |
| `app.yaml` (App Engine) | gcloud declarative |

For Terraform projects, also detect:

- Backend (state location): `terraform { backend "gcs" { ... } }`.
- Workspace pattern (envs as workspaces vs envs as directories).
- Module convention.
- Tooling: `terragrunt`, `tflint`, `tfsec`, `checkov`.

If there is **no IaC** and the user is asking for a non-trivial infra
change, surface that as a major risk: ad-hoc `gcloud` commands lose
reproducibility. Recommend bringing up a minimal Terraform setup first.

## Plan-then-apply discipline

This skill **plans**; it does not apply. The deliverable is:

1. A `terraform plan` (or equivalent) **dry-run** captured as text.
2. An IAM diff (who gains/loses access).
3. A cost estimate.
4. A rollback plan.

The user runs the apply themselves after reviewing.

### Running `terraform plan` (dry-run)

```bash
cd <terraform-dir>
terraform init -upgrade -backend-config=...   # if not already initialised
terraform fmt -check -recursive
terraform validate
terraform plan -out=plan.tfplan -detailed-exitcode -input=false
terraform show -json plan.tfplan > plan.json
```

`-detailed-exitcode`: 0=no changes, 2=changes, 1=error. The skill should
treat exit 1 as a hard fail and abort.

Capture `terraform show -no-color plan.tfplan` for human-readable output.

### gcloud preview (when bypassing Terraform)

For ad-hoc gcloud, use `--dry-run` / `--validate-only` where the resource
supports it:

```bash
gcloud compute instances create ... --dry-run
gcloud iam service-accounts create ... --validate-only
gcloud deployment-manager deployments update <dm> --preview
```

Not all gcloud commands support dry-run — flag clearly when planning
something that does not.

## IAM diff — required section

For every plan that changes IAM bindings, generate a delta matrix:

| Principal | Resource | Role before | Role after | Change |
|-----------|----------|-------------|------------|--------|
| serviceAccount:foo@... | projects/<id> | roles/storage.viewer | roles/storage.admin | **escalation** |
| user:alice@... | bucket://logs | (none) | roles/storage.objectAdmin | **grant** |

Flag any of these as 🔴 **Critical** unless the user explicitly justifies:

- Granting `roles/owner` or `roles/editor` to anyone.
- Granting `roles/iam.securityAdmin` or `roles/resourcemanager.projectIamAdmin`.
- Granting any role to `allUsers` or `allAuthenticatedUsers`.
- Cross-project bindings without an audit-logged service account.

For storage / network, separately surface:

- Public bucket creation.
- Open firewall rules (0.0.0.0/0 ingress).
- VPC peering / shared VPC changes.
- Public IP on a Cloud Run service that previously was internal.

## Cost estimation

Use whichever of these the project has access to; pick the cheapest:

| Tool | Best for |
|------|----------|
| `infracost breakdown --path .` | Terraform-only projects; AWS+GCP+Azure. Fast monthly delta. |
| GCP Pricing Calculator (manual) | Anyone, no setup; tedious for many resources. |
| Cloud Billing exports + BQ | When project already exports billing — query historical baseline + estimate delta. |

The deliverable should include at minimum:

- Estimated monthly cost delta (USD or NTD).
- Top 3 cost drivers (which resources contribute most).
- Cost-control levers (autoscale floors, retention windows, region choice).

## Rollback plan

Every infra plan must answer:

- **Reversible?** — can `terraform destroy <addr>` restore prior state, or does the change involve data (DB, GCS) that cannot be re-created?
- **Backups** — does this change require / depend on a backup taken first?
- **Blast radius** — if applied incorrectly, what is the worst case? (single env vs prod, single service vs project-wide).
- **Communication** — who needs to know before / during / after apply?

For irreversible changes (DB drop, IAM revocation cascading to secrets,
deletion of GCS objects), the spec must include a **STOP / read-aloud
checklist** that the operator runs before `terraform apply`.

## Network & security baseline

For any new public-facing resource:

- TLS termination — managed cert (`google_compute_managed_ssl_certificate`) or upstream LB? Cipher suite floor.
- WAF / Cloud Armor policy attached?
- Service-to-service auth: workload identity, not key files.
- Secrets: Secret Manager + IAM, not env vars in `terraform.tfvars`.
- Logs: VPC flow logs, audit logs, sink to a tamper-resistant location.

## Compliance / data residency

If the project has compliance constraints (SOC 2, HIPAA, GDPR, local data residency), every plan must verify:

- Resource regions are within allowed list.
- Backups respect residency too.
- Data crossing regions is justified (and may need DPA review).

## Test plan

Infra "tests" are a mix of:

| Layer | Tool | What it covers |
|-------|------|----------------|
| Static | `terraform fmt`, `terraform validate`, `tflint`, `tfsec`, `checkov` | Syntax, deprecations, common security mistakes. |
| Plan-only | `terraform plan -detailed-exitcode` | What WILL change. |
| Conformance | `conftest` + Rego policies, `terraform-compliance` BDD | Org-wide rules (no public buckets, etc.). |
| Smoke (post-apply) | curl / `gcloud ... describe` | Resource exists with expected config. |
| Drift | `driftctl` / `terraform plan` cron | Detect manual changes. |

Document which of these run in CI vs locally vs out-of-band.

## Common anti-patterns to flag

- ❌ Using `local-exec` / `null_resource` to paper over missing provider features — fragile and hides intent.
- ❌ Hardcoded project IDs / region names — use variables, even if there's only one env now.
- ❌ Editing resources in the GCP Console after Terraform owns them (drift).
- ❌ Storing state locally instead of GCS / S3 / Terraform Cloud.
- ❌ Using `count = 0` to "delete" — actually `terraform destroy <addr>` so the audit log is clean.
- ❌ A single PR changing IAM + resources + variables — split for reviewability.

## Deliverable

`/maestro.web.infra.plan` produces a sprint file:
`docs/<num>-<slug>/INFRA.md`:

```markdown
# Infra plan — <feature name>

## Summary
<1-paragraph: what changes, why now, blast radius>

## Resource changes
<terraform plan output, abridged + linked to plan.tfplan>

## IAM diff
<table; flag critical changes>

## Cost estimate
- Monthly delta: <USD>
- Top drivers: ...
- Levers: ...

## Network & security
<TLS, WAF, secrets, logs>

## Rollback plan
- Reversible? <yes/no, why>
- STOP-checklist (if irreversible)
- Comm plan

## Verification (post-apply)
- Smoke: <commands>
- Drift detection: <when>

## Open questions
- ...
```

Attach `plan.tfplan` and `plan.json` to the sprint dir for reviewers.
