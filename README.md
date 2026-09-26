Terraform-provisioned Amazon EKS platform demo with Python Flask, Java/Maven, and NGINX sample applications, GitHub Actions CI, Amazon ECR, Argo CD, Karpenter, Prometheus/Grafana, OpenTelemetry/Tempo, Velero, and AWS Secrets Manager.

## Architecture

GitHub Actions scans repository history with Gitleaks and tests/builds/scans app images on PRs and pushes to `develop`. Publishing is a manual promotion: choose an app and dev/QA target from `workflow_dispatch`; the workflow pushes an immutable image to that environment's ECR and opens a promotion PR. Merge the PR to let Argo CD deploy the chosen image.

Terraform provisions VPC, EKS, ECR, IAM, S3, and foundational Helm releases. Argo CD reconciles GitOps-managed add-ons and the sample apps from `platform/`.

## Repository Structure

```text
terraform/
  bootstrap/                 Terraform state bucket
  environments/dev/           Dev Terraform root, own state + tfvars
  environments/qa/             QA Terraform root, isolated state + smaller sizing
    backend.config.hcl         QA state key; uses shared backend bucket
    terraform.tfvars.example   QA network/node values
  modules/
    eks/                      EKS cluster and IAM
    karpenter/                Karpenter AWS IAM, SQS, and events
    container-registry/       Per-app ECR repositories and GitHub OIDC push role
    platform-aws/             Velero S3 and Pod Identity roles
    vpc/                      VPC and subnet resources
.github/workflows/            Application CI matrix, image publishing, promotion PRs
apps/
  python-demo/                Flask app, tests, dependencies, Dockerfile
  java-demo/                  Java 21/Maven app, JUnit tests, Dockerfile
  nginx-demo/                 Static site, NGINX config, Dockerfile
helm/apps/
  python-demo/                Local Helm chart for the Python app
  java-demo/                  Local Helm chart for the Java app
  nginx-demo/                 Local Helm chart for the NGINX app
platform/
  argocd/root.yaml            App-of-apps bootstrap
  argocd/qa-root.yaml         QA app-of-apps bootstrap
  argocd/apps/                Argo CD Applications (point to local charts or upstream charts)
  argocd/qa-apps/             QA Argo CD Applications
  karpenter/                  EC2NodeClass and NodePools
  karpenter/qa/               QA-specific Karpenter resources
  secrets/                    External Secrets store and demo secret
  secrets-qa/                 QA SecretStore and demo secret mapping
README.md
```

## Platform Add-ons: Current State

| Component | Installation/ownership | Status |
|---|---|---|
| EKS, VPC, EBS CSI, AWS Load Balancer Controller | Terraform | Configured; public API CIDRs must be set to trusted ranges |
| Metrics Server | Argo CD Helm Application | Configured for `kubectl top` and HPA resource metrics |
| Argo CD | Terraform Helm release | Configured; bootstraps `platform/argocd/root.yaml` |
| Karpenter controller and AWS IAM/Pod Identity | Terraform | Configured |
| Karpenter EC2NodeClass and NodePools | Argo CD | Configured after Terraform installs controller CRDs |
| Prometheus, Grafana, Alertmanager | Terraform Helm release | Configured |
| Tempo and OpenTelemetry Collector | Argo CD Helm applications | Configured; OTLP traces, metrics, and logs pipeline |
| AWS Secrets Manager | Terraform Pod Identity + External Secrets Operator | Configured; secret values remain in AWS |
| Velero and S3 backup bucket | Terraform S3/IAM + Terraform Helm release | Configured; bucket name comes from the active AWS account data source; Kopia file-system backups, no EBS snapshots |
| ECR and GitHub Actions publishing role | Terraform | Configured; per-app repositories, GitHub OIDC, immutable image tags |
| Python, Java, and NGINX samples | Flask, Java 21/Maven, NGINX | Configured; separate build contexts and Kubernetes services |
| Workload health and baseline pod security | App Helm charts + Argo CD | Startup/readiness/liveness probes, non-root, seccomp, no privilege escalation, read-only root filesystem where supported; `default` namespace uses restricted Pod Security Admission |
| Application CI and image promotion | GitHub Actions | Test/build/scan matrix; manually select app and dev/QA, publish to ECR, then review/merge a GitOps PR |
| HashiCorp Vault | — | Not installed; see note below |

### Deploy

1. **Prepare Terraform state storage once.** Using the intended AWS profile (for example, `sandbox3`), run `terraform init`, `terraform plan`, and `terraform apply` from `terraform/bootstrap`. This creates the shared S3 bucket. Confirm its name with `terraform output -raw terraform_state_bucket`.
2. **Prepare dev inputs.** Copy `terraform/environments/dev/terraform.tfvars.example` to `terraform.tfvars` in that folder. Confirm `cluster_endpoint_public_access_cidrs` is your trusted public IP `/32`; `velero_bucket_name = null` means derive a unique bucket from project, environment, and active AWS account. Review CIDR overlap before changing VPC ranges.
3. **Apply dev.** Confirm `terraform/environments/dev/backend.config.hcl` points to the state bucket from step 1 and uses key `dev/terraform.tfstate`. Run `terraform init -reconfigure -backend-config=backend.config.hcl`, then `terraform plan` and review it before `terraform apply`. This creates dev EKS/ECR, the first GitHub OIDC provider, Argo CD, Karpenter, Velero, and IAM roles. Save outputs `github_actions_ecr_role_arn` and `github_oidc_provider_arn`. If the first apply cannot configure Helm because the cluster does not exist yet, apply VPC/EKS first, then run a normal full plan/apply.
4. **Prepare QA when ready.** Copy `terraform/environments/qa/terraform.tfvars.example` to `terraform.tfvars`. Set your trusted API CIDR and set `github_oidc_provider_arn` from dev's output. The QA network is `10.1.0.0/16`; verify it doesn't overlap VPN/peered networks. Confirm `qa/backend.config.hcl` uses the same bucket as dev but key `qa/terraform.tfstate`. From `terraform/environments/qa`, run `terraform init -backend-config=backend.config.hcl`, then review `terraform plan` before `terraform apply`. QA creates its own cluster, ECR repos, backup bucket, and publisher role, but reuses the account's OIDC provider.
5. **Set GitHub variables.** Add Actions variables `AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_QA` from each environment's `terraform output -raw github_actions_ecr_role_arn`. Ensure the `GITHUB_TOKEN` can create pull requests and protect `develop`. The workflow file must also exist on GitHub's default branch for the **Run workflow** button to appear; when dispatching, select branch `develop`. Do not add AWS access keys.
6. **Test code.** Open a PR to `develop` or push app changes to `develop`. Gitleaks runs, and CI tests/builds/scans the Python, Java, and NGINX apps and lints/renders both chart value sets. Normal pushes do **not** publish images.
7. **Manually promote an image.** In GitHub Actions, select this workflow and choose **Run workflow**. Select branch `develop`, then choose app and target `dev` or `qa`. CI tests first; the publish job assumes that environment's OIDC role, pushes the commit-SHA image to its ECR repository, and opens a PR updating `helm/apps/<app>/values.yaml` for dev or `values-qa.yaml` for QA. Review and merge the PR; merging is the GitOps approval that changes desired state.
8. **Bootstrap Argo CD GitOps per cluster.** After the image-promotion PR is merged, set kubectl to the intended cluster context and apply `platform/argocd/root.yaml` for dev or `platform/argocd/qa-root.yaml` for QA. Each root points at its own Applications; QA Karpenter and secrets use QA-specific manifests. Update the repository URL/branch in these root/Application files if you fork the repo.
9. Create the matching AWS Secrets Manager secret (`eks-platform-demo/dev/demo-app` or `eks-platform-demo/qa/demo-app`) with JSON fields `username` and `password` to test External Secrets. Never commit secret values.

For a locally expiring AWS SSO session, renew it in PowerShell with `aws sso login --profile sandbox3`, then verify `aws sts get-caller-identity --profile sandbox3` reports the expected account before running Terraform. Set `$env:AWS_PROFILE = "sandbox3"` in that terminal. This AWS SSO session is unrelated to this chat session's context limit. GitHub Actions OIDC credentials are separately issued short-lived per workflow job.

The Python and Java samples emit OpenTelemetry traces to `opentelemetry-collector.monitoring.svc.cluster.local:4317` (gRPC); the NGINX sample serves a static page. Traces are sent to Tempo; Grafana has Tempo configured as a data source. No custom domain or public HTTPS endpoint is required.

Metrics Server provides resource metrics for `kubectl top` and future HorizontalPodAutoscalers. It is separate from Prometheus, which collects/stores monitoring time series. App probes are in the charts: startup probes protect slow launches, readiness controls Service traffic, and liveness restarts stuck containers.

### EBS PV/PVC demo

The Python app is a StatefulSet with two replicas. Kubernetes creates one 1-GiB PVC per pod from the `gp3-encrypted` StorageClass; the EBS CSI driver dynamically provisions encrypted gp3 PVs. Claims are per replica—not shared storage—and survive pod replacement. Python's `/persistent` endpoint increments a file on that pod's volume; its JSON response includes the pod name because each replica has its own counter. To demonstrate persistence, port-forward directly to one StatefulSet pod, call `/persistent` twice, delete only that pod (not its PVC), then reconnect to the recreated pod and call it again. The counter should continue. `kubectl top` does not report EBS capacity; inspect PVC/PV objects instead.

PowerShell demo (replace `dev` with the correct kubectl context): run `kubectl --context dev get pods -l app.kubernetes.io/name=python-demo`, then `kubectl --context dev port-forward pod/python-demo-0 8080:8080`. In another terminal call `Invoke-RestMethod http://localhost:8080/persistent` twice, stop the port-forward with Ctrl+C, run `kubectl --context dev delete pod python-demo-0`, wait for the replacement pod to become Ready, then port-forward again and call the endpoint. Inspect claims with `kubectl --context dev get pvc -l app.kubernetes.io/name=python-demo` and volumes with `kubectl --context dev get pv`. Delete the pod only; do not delete the StatefulSet or PVC when testing persistence.

Velero's node agent is configured to include the annotated `app-data` volume in filesystem backups. EBS snapshot-based backups/restores are still disabled, and restore has not been tested. PVCs and dynamically provisioned EBS volumes cost money and can remain after cluster teardown; inspect and remove them deliberately after the demo, preserving any data you need.

Each Argo CD root uses automated sync/prune. Review the applications and IAM scope before using this pattern outside a disposable demo account. The S3 backup bucket has Terraform deletion protection.

### Vault decision

This demo uses AWS Secrets Manager as the source of truth and External Secrets Operator to sync selected values into Kubernetes. Vault would duplicate that role and requires decisions about storage, TLS, initialization/unseal, authentication, backup, and upgrade ownership. It is intentionally not installed by default. Do not use Vault dev mode or commit root/unseal credentials.

### Known follow-up

Velero currently backs up Kubernetes resources and file-system data through its node agent; EBS CSI snapshots are disabled. Snapshot-based PV restore needs the CSI snapshot controller/CRDs, AWS snapshot permissions/location, and a tested restore procedure. Terraform CI/plan validation and a Vault deployment are also not included.

Terraform now requires trusted CIDRs for the public EKS API and enables EKS control-plane API, audit, authenticator, controller-manager, and scheduler logs (review CloudWatch retention/cost). Confirm EKS secret encryption is enabled for this cluster/version. Before shared/production use, add tested NetworkPolicies (the Amazon VPC CNI network-policy feature must be enabled first), configure AWS Budgets/alarms, and test Velero restore. The current Pod Security baseline applies to demo workloads in `default`; it is not a replacement for IAM least privilege or cluster-wide admission policy.

### Deployment locations and access

Terraform-managed Helm releases are centralized in each environment's `helm.tf`. Velero's bucket is derived from AWS caller identity unless overridden in that environment's tfvars. The Python, Java, and NGINX charts live in `helm/apps/`; dev and QA use separate Argo CD Application directories and the chart's dev/QA values files. Argo CD bootstrap remains Terraform-managed so it can start before managing other applications. Each environment has a tracked `backend.config.hcl` (shared non-secret state bucket, different state key) and `terraform.tfvars.example`; copy the latter to ignored `terraform.tfvars` for local inputs.

If Velero has already been installed by Argo CD in a cluster, do not let Terraform and Argo CD manage the release simultaneously. Before applying this ownership change, either uninstall it through Argo CD and then let Terraform install it, or import the existing Helm release into Terraform state and verify the plan before removing its Argo CD Application.

A custom domain and public HTTPS endpoint are not required. These applications use in-cluster Kubernetes Services; no Ingress or public LoadBalancer is configured for Argo CD, Grafana, Tempo, or the OpenTelemetry Collector. Use `kubectl port-forward` for local access during the demo. The AWS Load Balancer Controller being installed does not create an Internet-facing endpoint by itself.

### Terraform environment roots

Each directory under `terraform/environments/` is a separate Terraform root and state. `backend.tf` declares S3; that backend cannot read tfvars or data sources. The tracked `backend.config.hcl` supplies the shared bucket and environment-specific key. The local `terraform.tfvars` supplies ordinary Terraform variables and is git-ignored; its `.example` is committed. QA has its own cluster, ECR repositories, Velero bucket, Argo CD applications, chart values, and Karpenter resources. It reuses the one account-wide GitHub OIDC provider created by dev.

Image promotion is intentionally manual. `workflow_dispatch` requires choosing an app and environment and must be run from `develop`; it creates a PR after pushing to that environment's ECR. Configure GitHub Actions variables `AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_QA` using each Terraform root's `github_actions_ecr_role_arn` output. The PR merge—not the workflow run by itself—is what updates Git's desired image tag and allows Argo CD to deploy it.