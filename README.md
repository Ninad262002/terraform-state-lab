# Terraform State Management, Remote Backend & Drift Detection Pipeline

A hands-on DevOps project covering Terraform state management on AWS: a secure S3 remote backend with native state locking, practical `terraform state` operations, drift detection and reconciliation, and a CI pipeline on GitHub Actions that authenticates to AWS using OIDC (no long-lived access keys).

---

## Table of Contents

1. [Architecture](#architecture)
2. [Tech Stack](#tech-stack)
3. [Repository Structure](#repository-structure)
4. [Prerequisites](#prerequisites)
5. [Phase 1: Remote Backend and State Locking](#phase-1-remote-backend-and-state-locking)
6. [Phase 2: State Management Commands](#phase-2-state-management-commands)
7. [Phase 3: Drift Detection and Reconciliation](#phase-3-drift-detection-and-reconciliation)
8. [Phase 4: CI/CD with GitHub Actions](#phase-4-cicd-with-github-actions)
9. [Troubleshooting](#troubleshooting)
10. [Lessons Learned](#lessons-learned)
11. [Cleanup](#cleanup)
12. [Future Enhancements](#future-enhancements)

---

## Architecture

```
                    ┌──────────────────────────┐
                    │      Developer laptop     │
                    │  Terraform CLI + AWS CLI  │
                    └────────────┬─────────────┘
                                 │ git push / PR
                                 ▼
                    ┌──────────────────────────┐
                    │     GitHub Repository     │
                    │  GitHub Actions workflow  │
                    └────────────┬─────────────┘
                                 │ 1. request OIDC token
                                 │ 2. AssumeRoleWithWebIdentity
                                 ▼
                    ┌──────────────────────────┐
                    │  AWS IAM (OIDC provider   │
                    │  + plan role, read-only)  │
                    └────────────┬─────────────┘
                                 │ temporary credentials
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │                        AWS (ap-south-1)                    │
   │                                                            │
   │  S3 state bucket                 Managed test resources    │
   │  - versioning enabled            - S3 buckets (demo,       │
   │  - AES256 encryption               rescued, drift test)    │
   │  - public access blocked         - child module (logging)  │
   │  - native locking (.tflock)                                │
   └───────────────────────────────────────────────────────────┘
```

**Two Terraform root modules:**

| Folder | Purpose | State location |
|---|---|---|
| `bootstrap/` | Creates the state bucket and the GitHub OIDC provider and IAM role | Local (small, rarely changes) |
| `infra/` | Test resources used to practice state operations and drift | Remote (S3) |

This split avoids the chicken-and-egg problem: the backend bucket cannot store its own state before it exists.

## Tech Stack

- Terraform >= 1.11 (S3 native locking via `use_lockfile`)
- AWS provider ~> 6.0, random provider ~> 3.6
- AWS: S3, IAM, STS
- GitHub Actions with OIDC
- Region: `ap-south-1`

## Repository Structure

```
terraform-state-lab/
├── .github/
│   └── workflows/
│       └── terraform-plan.yml      # PR: fmt, init, validate, plan
├── .gitignore
├── README.md
├── bootstrap/
│   ├── main.tf                     # State bucket, versioning, encryption, public access block
│   ├── oidc.tf                     # GitHub OIDC provider, IAM role, policies
│   ├── variables.tf
│   └── outputs.tf
└── infra/
    ├── backend.tf                  # S3 backend with use_lockfile
    ├── versions.tf                 # Terraform and provider versions
    ├── main.tf                     # Test resources
    ├── .terraform.lock.hcl         # Provider lock (windows_amd64 + linux_amd64)
    └── modules/
        └── logging/                # Child module used in the refactoring exercise
```

Never committed: `*.tfstate*`, `.terraform/`, `state-backups/`, `*.tfvars`.

## Prerequisites

- AWS account and an IAM user or role with sufficient permissions (S3, IAM)
- Terraform 1.11 or newer
- AWS CLI configured (`aws sts get-caller-identity` works)
- Git and a GitHub account
- VS Code (optional)

## Phase 1: Remote Backend and State Locking

### Concepts

- **State** maps resources in code to real infrastructure IDs, and stores their attributes.
- **Configuration** is the desired state, **state** is what Terraform believes exists, **actual infrastructure** is reality. `terraform plan` compares all three.
- Local state cannot be shared, has no locking, no versioning, and may contain secrets.

### Bootstrap the backend

```bash
cd bootstrap
terraform init
terraform apply
terraform output state_bucket_name
```

The bootstrap creates an S3 bucket with:

- Versioning enabled (recover from corrupted or overwritten state)
- Server-side encryption (AES256)
- Public access fully blocked

### Configure the backend and migrate state

`infra/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "<STATE_BUCKET_NAME>"
    key          = "infra/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

Safe migration procedure:

```bash
# 1. Back up the local state first
cp terraform.tfstate ../state-backups/pre-migration.tfstate

# 2. Migrate
terraform init -migrate-state

# 3. Verify: must report "No changes"
terraform plan
```

### S3 native locking vs DynamoDB locking

| | S3 native (`use_lockfile`) | DynamoDB (`dynamodb_table`) |
|---|---|---|
| Mechanism | Conditional write creates `<key>.tflock` in S3 | Item in a DynamoDB table |
| Extra resources | None | A table to create and manage |
| Terraform version | 1.10+ (stable in 1.11+) | Works on older versions |
| Status | Recommended | Deprecated |

Compatibility note: every engineer and CI runner must use Terraform 1.10 or newer, otherwise `use_lockfile` is not understood. Pin the version in CI.

### Locking test

1. Terminal 1: run `terraform apply` and stop at the confirmation prompt (lock is held).
2. Terminal 2: run `terraform plan`. It fails with `Error acquiring the state lock` (HTTP 412 from S3).
3. `aws s3 ls s3://<bucket>/infra/` shows `terraform.tfstate.tflock`.
4. Answer `no` in Terminal 1. The lock file disappears.

If a lock is stuck: `terraform force-unlock <LOCK_ID>`, but only after confirming no other operation is running. It removes the lock only, never state or infrastructure.

## Phase 2: State Management Commands

| Command | Changes state | Changes AWS |
|---|---|---|
| `terraform state list` | No | No |
| `terraform state show <addr>` | No | No |
| `terraform state mv <from> <to>` | Yes | No |
| `terraform state rm <addr>` | Yes | No |
| `import` block + `apply` | Yes | No (unless attributes differ) |
| `moved` block + `apply` | Yes | No |

Always back up before risky operations:

```bash
terraform state pull > ../state-backups/pre-change.tfstate
# Restore if needed:
terraform state push ../state-backups/pre-change.tfstate
```

### Rename without destroying (`state mv` and `moved`)

Renaming a resource in code makes Terraform plan a destroy and create, because the address is the identity.

```bash
terraform state mv -dry-run aws_s3_bucket.practice aws_s3_bucket.logs
terraform state mv aws_s3_bucket.practice aws_s3_bucket.logs
```

Declarative and preferred for teams (reviewed in Git, applied automatically for everyone):

```hcl
moved {
  from = aws_s3_bucket.logs
  to   = aws_s3_bucket.access_logs
}
```

### Move a resource into a child module

```hcl
module "logging" {
  source      = "./modules/logging"
  bucket_name = "tfstate-lab-practice-${random_id.suffix.hex}"
  tags        = { Project = "terraform-state-lab", ManagedBy = "terraform" }
}

moved {
  from = aws_s3_bucket.access_logs
  to   = module.logging.aws_s3_bucket.this
}
```

Success criteria: the plan shows `0 to add, 0 to change, 0 to destroy`, and the bucket creation date is unchanged.

### Remove from state and re-import

```bash
terraform state rm module.logging.aws_s3_bucket.this   # AWS resource stays
```

```hcl
resource "aws_s3_bucket" "rescued" {
  bucket = "<EXISTING_BUCKET_NAME>"
  tags   = { Project = "terraform-state-lab", ManagedBy = "terraform" }
}

import {
  to = aws_s3_bucket.rescued
  id = "<EXISTING_BUCKET_NAME>"
}
```

`terraform plan` should show `1 to import, 0 to add, 0 to change, 0 to destroy`. Any `change` or `replace` means the code does not match the real resource. Review before applying.

## Phase 3: Drift Detection and Reconciliation

**Drift** is when actual infrastructure differs from state or configuration, usually because of manual console changes.

### Demonstration

1. Create `aws_s3_bucket.drift_test` with tags (`Environment = "dev"`) and apply.
2. In the AWS Console, change `Environment` to `prod` and add a tag `ChangedBy`.
3. Run `terraform plan`. Terraform refreshes, detects the difference, and shows an in-place update (`~`) to revert the tags.

### Two ways to reconcile

| | Trust code | Trust reality |
|---|---|---|
| When | Manual change was a mistake | Manual change was intentional |
| Action | `terraform apply` | Update `.tf` files, confirm `plan` shows no changes |
| Modifies | AWS | Configuration |

### Refresh-only

```bash
terraform plan -refresh-only     # shows how state would be updated, no changes made
terraform apply -refresh-only    # updates state only, AWS and config untouched
```

Use it to audit drift or to record an intentional manual change in state. Afterwards a normal `plan` can still show a difference, because configuration has not changed. The legacy `terraform refresh` command is replaced by this safer, reviewable workflow.

## Phase 4: CI/CD with GitHub Actions

### Authentication with OIDC

Created in `bootstrap/oidc.tf`:

1. **OIDC provider** for `token.actions.githubusercontent.com`
2. **IAM role** with a trust policy locked to this repository via the `sub` claim
3. **Permissions**: `ReadOnlyAccess` plus access to the `infra/*` prefix of the state bucket (plan acquires a lock, so it needs `PutObject` and `DeleteObject`)

The `sub` condition is what restricts the role to this repository. Without it, any GitHub repository could assume the role.

### Workflow

`.github/workflows/terraform-plan.yml` runs on pull requests to `main` that change `infra/**`:

1. Checkout
2. Setup Terraform (pinned version)
3. Configure AWS credentials via OIDC (`permissions: id-token: write` is required)
4. `terraform fmt -check -recursive`
5. `terraform init -input=false`
6. `terraform validate`
7. `terraform plan -input=false -no-color`

The pipeline never applies changes from a pull request. The role ARN is stored in the GitHub repository variable `AWS_ROLE_ARN` (not sensitive).

### Lock file for multiple platforms

The development laptop is Windows and the runner is Linux:

```bash
terraform -chdir=infra providers lock -platform=windows_amd64 -platform=linux_amd64
```

### Extending the pipeline with an approval gate (optional)

1. Create a GitHub Environment `production` with required reviewers.
2. Add a separate apply workflow that runs only on push to `main`, with `environment: production`.
3. Create a separate, write-capable IAM role for apply, trusted only for the `environment:production` subject.
4. Enable branch protection on `main` (require PR and passing checks).
5. Best practice: save the plan with `-out` on the PR and apply that exact plan, so what was reviewed is what is applied.

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `No valid credential sources found` | AWS credentials not configured | `aws configure` or check `aws sts get-caller-identity` |
| `AccessDenied` on state bucket | Missing S3 permissions | Grant `ListBucket`, `GetObject`, `PutObject`, `DeleteObject` |
| `Unsupported argument "use_lockfile"` | Terraform older than 1.10 | Upgrade Terraform |
| `Backend configuration changed` | Backend block edited | `init -migrate-state` to move state, `init -reconfigure` to just reload config |
| Plan shows everything "to add" after migration | State not migrated (for example `-reconfigure` used) | Do not apply. Restore from backup and migrate properly |
| `Error acquiring the state lock` | Another operation, or a crashed run | Wait, or verify and `terraform force-unlock <ID>` |
| `1 to add, 1 to destroy` after rename | Address changed without `moved` or `state mv` | Add a `moved` block or run `state mv` |
| `Cannot import non-existent remote object` | Wrong import ID | Copy the exact bucket name from `aws s3 ls` |
| Plan shows `replace` after import | Code does not match the real resource | Align arguments such as `bucket` and tags |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` does not match the token | Print the token's `sub` claim in a debug step and match it exactly (see below) |
| `Credentials could not be loaded` | `id-token: write` missing or `AWS_ROLE_ARN` empty | Check workflow permissions and the repository variable |
| `terraform fmt` fails in CI | Unformatted code | Run `terraform fmt -recursive` locally |
| `state snapshot was created by a newer Terraform` | CI Terraform older than the version that wrote the state | Pin the CI version to match local |
| `Failed to query available provider packages` in CI | Lock file lacks Linux hashes | Re-run `providers lock` with both platforms |

### OIDC subject format

GitHub can issue tokens whose `sub` includes immutable numeric IDs, for example:

```
repo:<owner>@<owner_id>/<repo>@<repo_id>:pull_request
```

If the trust policy uses the plain `repo:<owner>/<repo>:...` form, role assumption fails. To find the exact value, temporarily add a workflow step that decodes the OIDC token and prints the `sub` claim, then copy that value into the trust policy. Remove the debug step afterwards.

## Lessons Learned

1. The state file is the mapping between code and real resources. Losing or corrupting it is dangerous, which is why versioning, backups, and locking matter.
2. Versioning protects state history, not infrastructure.
3. The bootstrap pattern solves the backend chicken-and-egg problem.
4. Back up before every risky state operation, and verify with `terraform plan` afterwards (the goal is "No changes").
5. `moved` and `import` blocks are preferred over the imperative CLI commands because they are reviewable in Git and applied consistently for every engineer and the CI pipeline.
6. Refactoring must never show a destroy in the plan. Read the plan for the word "destroy" before every apply.
7. Drift has two resolutions: change infrastructure to match code, or change code to match infrastructure. Decide by asking which one is correct.
8. OIDC removes long-lived keys. The `sub` condition is the real security control, and debugging it means inspecting the actual token claims instead of guessing.
9. Separate roles for plan (read-only) and apply (write) limit blast radius.
10. Commit `.terraform.lock.hcl` (with hashes for every platform in use). Never commit state or `.terraform/`.

## Cleanup

AWS resources can incur charges. S3 buckets that are empty cost almost nothing, but clean up when finished.

**Test resources only (keeps the backend and CI foundation):**

```bash
cd infra
terraform destroy
```

Review the plan first. It should list only the test S3 buckets and `random_id.suffix`.

**Keep these if you want to reuse the project:**

- State bucket (`bootstrap/`)
- GitHub OIDC provider and the plan IAM role

**Full teardown (only when completely done):**

1. Run `terraform destroy` in `infra/`.
2. Empty all object versions in the state bucket (versioning is on), then run `terraform destroy` in `bootstrap/`.
3. Delete the GitHub repository variable `AWS_ROLE_ARN` and any GitHub Environments created.

## Future Enhancements

- Approval-gated apply workflow with a dedicated apply role
- Post the plan output as a pull request comment
- Scheduled workflow running `terraform plan -detailed-exitcode` to detect drift automatically
- Security and policy scanning (for example tfsec or Checkov) in the pipeline
- Separate state keys per environment (dev, staging, prod)
