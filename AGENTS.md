# Repository Guidelines

## Project Structure & Module Organization

This repository runs a single long-lived environment, edited and committed in place. Layout:

- Repository root is the app stack (`main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `versions.tf`) — VPC, ALB/ACM, EC2, RDS.
- `dns/` is a separate mini-stack owning the Route53 hosted zone, kept apart so destroying the app stack never deletes the zone (a zone re-create would assign new NS servers and force re-delegation at the registrar).
- `modules/` for reusable infrastructure components (`network`, `security`, `compute`, `database`, `ingress`, `storage`, `analysis`, `monitoring`, `github-actions`, `admin-access`).
- `docs/` for runbooks and recovery procedures.

If multiple environments are ever needed again, reintroduce `environments/<name>/` compositions over the same modules.

Do not commit generated plans, local state, caches, or provider downloads.

## Build, Test, and Development Commands

Plain Terraform commands, run from the repository root (add `-chdir=dns` for the zone stack):

```sh
terraform fmt -recursive # format all HCL
terraform validate       # static validation
terraform plan           # preview changes
```

`plan` runs automatically on every PR (`.github/workflows/terraform-plan.yml`, read-only role) and `apply` runs on merge to `main` (`terraform-apply.yml`). Review the plan comment on the PR before merging — merging *is* the approval. Only `modules/github-actions` changes (the CI roles themselves) and the first bootstrap need a local `apply`. Never automate `destroy`; run it manually and deliberately.

## Coding Style & Naming Conventions

Use each tool's canonical formatter and commit its configuration. Use two-space indentation for YAML and Markdown lists; let language formatters govern code and HCL. Name directories in lowercase kebab-case, reusable modules by capability (`network`, `database`), and variables or outputs in `snake_case`. Keep environment-specific values outside reusable modules and document every non-obvious default.

## Testing Guidelines

Every change should pass formatting, static validation, and tests before review. Infrastructure changes must also include a non-destructive plan for the affected environment. Add regression coverage for module behavior, policy rules, and failure-prone configuration. Tests must not require production credentials or mutate shared resources.

## Commit & Pull Request Guidelines

Git conventions follow `.claude/spec/git-convention.md`, shared with the server repository: Korean noun-phrase subjects in the form `{type}: 내용(#이슈번호)` (e.g. `feat: 프라이빗 서브넷 추가(#12)`), work branches named `{type}/{issue}-{slug}` branching from and merging back to `main`.

Pull requests follow `.github/pull_request_template.md`: link the issue, describe the changes, summarize plan output, and explain rollout and rollback. Call out replacements, deletions, permission changes, and expected downtime explicitly.

## Security & Configuration

Never commit credentials, private keys, state files, or customer data. Provide sanitized examples (`*.example`) and document required secret-store entries by name only. Pin tooling and provider versions, review lockfile changes, and use least-privilege access for local and CI execution.
