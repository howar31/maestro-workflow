---
name: web-infra-plan
description: Produce a sprint INFRA.md covering Terraform / gcloud changes — dry-run plan, IAM diff, cost estimate, rollback. Coordinator-only — does not apply infra changes. Pauses for user confirmation. Bias toward GCP+Terraform but works with Pulumi / CloudFormation / Serverless / CDK.
disable-model-invocation: true
---

# /magi:web-infra-plan — infra elaboration

You are the coordinator. Plan an infrastructure change and capture the
analysis in `magi/<num>-<slug>/INFRA.md`. **You never run `terraform apply`,
`gcloud ... create`, or any other resource-mutating command.** Read
`references/domain/web/infra.md` before starting.

## 0. Preflight

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[[ -z "$PLUGIN_ROOT" ]] && PLUGIN_ROOT="$(cd "$(dirname "$BASH_SOURCE[0]")/../.." 2>/dev/null && pwd)"
USER_CONFIG="$HOME/.config/magi-workflow/config.json"
```

If config missing → tell user to run `/magi:setup`.


## 0.5. State preflight (auto-refuse if not allowed)

```bash
STATE_JSON=$(bash "$PLUGIN_ROOT/scripts/shared/detect-state.sh")
blocked=$(jq -r '.disallowed_skills["web-infra-plan"] // empty' <<<"$STATE_JSON")
if [[ -n "$blocked" ]]; then
  reason=$(jq -r '.disallowed_skills["web-infra-plan"].reason' <<<"$STATE_JSON")
  suggest=$(jq -r '.disallowed_skills["web-infra-plan"].suggest' <<<"$STATE_JSON")
  echo "Cannot run /magi:web-infra-plan: $reason"
  echo "Suggested: $suggest"
  exit 1
fi
```

`--force` skips preflight (advanced/recovery only).

## 1. Locate sprint + IaC

Find the sprint folder (default: most recent; or `--sprint <num>-<slug>`).

Detect IaC tool per `references/domain/web/infra.md` "Discovery". Check:

- Is there a `*.tf` / `terraform/` / `pulumi.yaml` / `cloudformation/` etc.?
- For Terraform: where is the state? Workspace pattern? Tooling
  (`terragrunt`, `tflint`, `tfsec`, `checkov`)?

If there is NO IaC and the user is asking for non-trivial cloud changes,
**push back**: surface "no IaC = no reproducibility" as a 🔴 risk and
recommend introducing a minimal Terraform setup before proceeding.

## 2. Read the existing spec

Read PLAN/SPEC.md to understand what infra change is implied. If the spec
is silent on infra, ask the user to describe the intended change.

## 3. Generate the dry-run plan

Per `references/domain/web/infra.md`, run the appropriate dry-run:

### Terraform

```bash
cd <terraform-dir>
terraform fmt -check -recursive
terraform validate
terraform plan -out=plan.tfplan -detailed-exitcode -input=false
plan_rc=$?     # 0=no changes, 2=changes, 1=error
[[ $plan_rc -eq 1 ]] && abort  # surface the error to the user
terraform show -no-color plan.tfplan > "$sprint_dir/plan.txt"
terraform show -json plan.tfplan > "$sprint_dir/plan.json"
```

### gcloud (no Terraform)

For each gcloud command in the proposed change:

- Add `--dry-run` or `--validate-only` if supported.
- If not supported, mark it 🟡 in INFRA.md as "no dry-run available; review carefully before apply".

### Pulumi

```bash
pulumi preview --diff --json > "$sprint_dir/preview.json"
```

### CloudFormation

```bash
aws cloudformation create-change-set ... --change-set-type CREATE
aws cloudformation describe-change-set ... > "$sprint_dir/changeset.json"
```

If the dry-run cannot be run for any reason (no creds, no state lock,
network), abort and tell the user — never make up a fake plan.

## 4. IAM diff

Build the IAM impact table (per reference). For each binding change,
identify principal × resource × role-before × role-after.

Flag as 🔴 Critical anything in the reference's "elevated risks" list:

- `roles/owner`, `roles/editor`
- `roles/iam.securityAdmin`, `roles/resourcemanager.projectIamAdmin`
- `allUsers` / `allAuthenticatedUsers`
- Cross-project bindings without audit-logged SA
- Newly public bucket / firewall rule / Cloud Run service

## 5. Cost estimate

Pick the cheapest available tool:

```bash
# Preferred for Terraform projects:
infracost breakdown --path "$sprint_dir/plan.json" \
  --format table > "$sprint_dir/cost.txt" 2>&1 \
  || echo "infracost unavailable; falling back to manual estimate"
```

If `infracost` is missing, do a manual estimate using:

- Resource shape (machine type, region, storage class, retention).
- Public GCP / AWS / Azure pricing.
- Top 3 cost drivers.
- Cost-control levers.

State the methodology in INFRA.md so a reviewer can sanity-check.

## 6. Rollback plan

For every change, answer:

- **Reversible?** Can `terraform destroy <addr>` (or equivalent) restore
  prior state without data loss?
- **Backup needed first?** For DB / GCS / KMS / IAM cascading changes:
  yes, document the backup command.
- **Blast radius**: per-env vs cross-env vs whole project.
- **Comm plan**: who needs to know before / during / after apply.

For IRREVERSIBLE changes, INFRA.md must include a **STOP-checklist**
the operator runs aloud before applying:

```
STOP — irreversible apply ahead.
Confirm:
  [ ] Backup taken: <command and verified output>
  [ ] Approver: <name>
  [ ] Rollback path documented and tested
  [ ] Off-hours window: <timestamp>
```

## 7. Write INFRA.md

Use the deliverable template from `references/domain/web/infra.md`. Fields:

- Summary
- Resource changes (link to plan.tfplan / plan.txt)
- IAM diff table
- Cost estimate
- Network & security baseline check (TLS, WAF, secrets, logs)
- Rollback plan (+ STOP checklist if applicable)
- Verification (post-apply smoke commands; drift detection cadence)
- Open questions

Use `output_language` for prose; keep CLI commands and resource names in
English / canonical form.

## 8. Stop and hand off

Show the user:
- INFRA.md path
- Top 3 risks (especially any 🔴 IAM escalations)
- Cost delta summary
- Whether the change is reversible

Recommend next:
- If risks are 🔴: have user re-run `/magi:review-plan` so other models
  also see the IAM diff.
- If clean: tell user the apply commands they should run themselves
  (DO NOT run them).
- If something is missing for a clean apply (creds, backup), surface that.

**Never run `terraform apply` or any mutating gcloud command.**

## Argument parsing

- `--sprint <num>-<slug>` — explicit sprint folder.
- `--iac terraform|pulumi|cloudformation|gcloud` — skip detection.
- `--terraform-dir <path>` — explicit terraform directory if not at sprint root.
- `--no-cost` — skip cost estimation (rare; usually wanted).
- `--no-iam-diff` — skip IAM diff (only for changes that don't touch IAM).

## Conventions

- **Plan, not apply** — this skill never mutates state.
- **Always dry-run first** — even for "trivial" changes; the dry-run is the
  artefact reviewers compare against the apply.
- **Errors are blocking** — `terraform plan` returning 1 = abort; do not
  guess at the missing pieces.
- **IAM is rarely "small"** — even one role addition can be Critical.
  Be paranoid by default.
- **Cost methodology must be stated** — an unattributed number is worse
  than no number.
