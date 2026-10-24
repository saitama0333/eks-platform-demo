# GitLab CI setup

The GitLab pipeline is an optional alternative to the existing GitHub Actions
workflow. It does not change GitHub configuration. The root pipeline
`.gitlab-ci.yml` includes jobs from `.gitlab/ci/`:

1. **Security:** Gitleaks scans the checked-out Git history.
2. **Validate:** Helm lints and renders all three application charts for dev
   and QA.
3. **Test:** Python unit tests and dependency audit; Java Maven verification.
4. **Image:** builds each app image, runs the NGINX health smoke check, and
   fails on critical unfixed Trivy findings.
5. **Publish:** a manual job can build/push one image to dev or QA ECR, update
   that environment's Helm values, and open a GitLab merge request to
   `develop`.

The first four stages run on branches and merge requests. Publishing is
available only for a manually started pipeline on `develop`. Set `APP_NAME`
to `python-demo`, `java-demo`, or `nginx-demo`, and `TARGET_ENV` to `dev` or
`qa` when starting the pipeline.

## Runner and project settings

The image and publish jobs need a GitLab Docker executor with privileged Docker
in-Docker enabled. The publish job installs AWS CLI, Bash, Git, curl, jq, and
Python into the job image. Configure the project to allow the protected
`develop` branch to run publishing jobs. Protect and mask `GITLAB_API_TOKEN`;
use a project access token with only the scopes/role needed to push a promotion
branch and open a merge request. Never place AWS access keys in CI variables.

The pipeline expects these GitLab project or group variables:

| Variable | Required for | Value |
| --- | --- | --- |
| `AWS_ROLE_ARN_DEV` | Dev image publish | Terraform output `github_actions_ecr_role_arn` (the existing ECR push role is shared by GitHub/GitLab). |
| `AWS_ROLE_ARN_QA` | QA image publish | QA Terraform output `github_actions_ecr_role_arn`. |
| `GITLAB_API_TOKEN` | Promotion merge request | Masked, protected project access token with write access to the repository and API access to create MRs. |

The AWS roles are assumed with a short-lived GitLab OIDC token. The token is
restricted to this GitLab project path and the `develop` branch. Terraform's
GitLab trust is **disabled by default**, so validation jobs work without any
AWS setup and the publish job will not assume a role until you opt in.

## Enable GitLab OIDC in AWS

1. Confirm the exact GitLab namespace/project path. Update
   `gitlab_project_path` in the environment's local Terraform variables if it
   differs from `saitama0333/eks-platform-demo`.
2. In dev `terraform.tfvars`, set `enable_gitlab_oidc = true` and
   `create_gitlab_oidc_provider = true`. Keep the provider account-scoped; do
   not create a duplicate provider from QA.
3. Run and inspect a normal dev Terraform plan. Confirm it creates the
   `https://gitlab.com` IAM OIDC provider and adds exactly one trust statement
   for the configured project's `develop` branch to the existing dev ECR
   publishing role. Apply only after reviewing that plan.
4. Save `terraform output -raw gitlab_oidc_provider_arn`. In QA, set
   `enable_gitlab_oidc = true`, `create_gitlab_oidc_provider = false`, and
   `gitlab_oidc_provider_arn` to the dev output. Plan and review QA before
   applying.
5. Set `AWS_ROLE_ARN_DEV`/`AWS_ROLE_ARN_QA` and the protected
   `GITLAB_API_TOKEN` variables described above. Start a pipeline on `develop`
   with the app/environment variables, inspect the job, then run the manual
   publish job.

Do not enable GitLab OIDC until the GitLab project path and branch protection
are correct. The trust policy intentionally excludes feature branches and
merge-request refs. The pipeline publishes images; the merge request changes
only the selected `helm/apps/<app>/values-<environment>.yaml` file. Merge it to
let Argo CD deploy the immutable image tag.

## Scope and limitations

GitLab CI currently covers application checks and image promotion. Terraform
format/validate/plan and Kubernetes deployment are not CI jobs. Terraform
applies and Argo CD installation remain operator-run steps in the deployment
runbook. This avoids granting CI broad infrastructure or cluster credentials.
