Terraform-provisioned Amazon EKS platform demo with Python Flask, Java/Maven, and NGINX sample applications, GitHub Actions CI, Amazon ECR, Argo CD, Karpenter, Prometheus/Grafana, OpenTelemetry/Tempo, Velero, and AWS Secrets Manager.

## Architecture

GitHub Actions scans repository history with Gitleaks and tests/builds/scans app images on PRs and pushes to `develop`. Publishing is a manual promotion: choose an app and dev/QA target from `workflow_dispatch`; the workflow pushes an immutable image to that environment's ECR and opens a promotion PR. Merge the PR to let Argo CD deploy the chosen image.

Terraform provisions VPC, EKS, ECR, IAM, and S3. Argo CD reconciles platform components from `platform/addons/` and sample workloads from `platform/apps/`.

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
  addons/dev/<addon>/         Dev Argo CD Application and Helm values per add-on
  addons/qa/<addon>/          QA Argo CD Application and Helm values per add-on
  apps/dev/<app>/             Dev workload Applications (Python, Java, NGINX)
  apps/qa/<app>/              QA workload Applications (Python, Java, NGINX)
  karpenter/dev/              Dev EC2NodeClass and NodePools
  karpenter/qa/               QA EC2NodeClass and NodePools
  secrets/                    External Secrets store and demo secret
  secrets-qa/                 QA SecretStore and demo secret mapping
README.md
```

### Where platform resources live

| Resource | Location |
|---|---|
| Prometheus, Grafana, Alertmanager | `platform/addons/<environment>/prometheus/`; Grafana is enabled inside the kube-prometheus-stack chart |
| OpenTelemetry Collector, Tempo, Velero | `platform/addons/<environment>/<addon>/`; each chart has an `application.yaml` and sibling `values.yaml` |
| Karpenter controller chart | `platform/addons/<environment>/karpenter/` |
| Karpenter EC2NodeClass and NodePools | `platform/karpenter/<environment>/` |
| External Secrets Kubernetes manifests | `platform/secrets/` for dev and `platform/secrets-qa/` for QA |
| ECR repositories and GitHub OIDC publishing role | `terraform/modules/container-registry/` |
| Velero S3 bucket and add-on IAM roles | `terraform/modules/platform-aws/` |
| Demo source code and charts | `apps/` and `helm/apps/`, respectively |

There is no separate `platform/observability/` directory: observability is kept with the other environment-specific add-ons. The old empty placeholder directories have been removed.

## Platform Add-ons: Current State

| Component | Installation/ownership | Status |
|---|---|---|
| EKS, VPC, EBS CSI | Terraform | Configured; public API CIDRs must be set to trusted ranges |
| Metrics Server | Argo CD Helm Application | Configured for `kubectl top` and HPA resource metrics |
| Argo CD bootstrap | Helm CLI during initial cluster setup | Install after EKS creation; manage upgrades outside the environment Terraform roots |
| AWS Load Balancer Controller, kube-prometheus-stack, Karpenter controller, Velero | Argo CD Applications under `platform/addons/<environment>/` | Terraform no longer declares Helm releases; Velero sync waits for bucket configuration |
| Karpenter AWS IAM/Pod Identity | Terraform | Configured |
| Karpenter EC2NodeClass and NodePools | Argo CD | Requires the running Karpenter controller CRDs |
| Prometheus, Grafana, Alertmanager | Argo CD Application under `platform/addons/<environment>/prometheus/` | Configured through the per-environment values file |
| Tempo and OpenTelemetry Collector | Argo CD Helm applications | Configured; OTLP traces, metrics, and logs pipeline |
| AWS Secrets Manager | Terraform Pod Identity + External Secrets Operator | Configured; secret values remain in AWS |
| Velero S3 backup bucket and IAM | Terraform S3/IAM | Bucket name comes from the active AWS account data source; Argo CD values configure Kopia file-system backups, no EBS snapshots |
| ECR and GitHub Actions publishing role | Terraform | Configured; per-app repositories, GitHub OIDC, immutable image tags |
| Python, Java, and NGINX samples | Flask, Java 21/Maven, NGINX | Configured; separate build contexts and Kubernetes services |
| Workload health and baseline pod security | App Helm charts + Argo CD | Startup/readiness/liveness probes, non-root, seccomp, no privilege escalation, read-only root filesystem where supported; `default` namespace uses restricted Pod Security Admission |
| Application CI and image promotion | GitHub Actions | Test/build/scan matrix; manually select app and dev/QA, publish to ECR, then review/merge a GitOps PR |
| HashiCorp Vault | — | Not installed; see note below |

### Deploy

1. **Choose the Terraform state bucket before initializing.** The environment roots currently hardcode `tf-gitops-nikhil` in `eu-central-1`, with separate dev and QA state keys. Their `backend.config.hcl` files are comments only. The bootstrap root creates a different bucket named from the project and AWS account, in the AWS provider's default region. If you want that new bucket, update both environment `backend.tf` files with its output name and region before initializing. If the hardcoded bucket already exists and is your intended backend, keep it and skip bootstrap. Do not switch buckets for an environment that already has state without planning a state migration.
2. **Prepare dev inputs.** Copy `terraform/environments/dev/terraform.tfvars.example` to `terraform.tfvars` in that folder. Set `cluster_endpoint_public_access_cidrs` to your trusted public IP `/32`; `velero_bucket_name = null` means derive a unique bucket from project, environment, and active AWS account. Review CIDR overlap before changing VPC ranges.
3. **Apply dev.** From `terraform/environments/dev`, run `terraform init`, then `terraform plan` and review it before `terraform apply`. This creates dev EKS/ECR, the first GitHub OIDC provider, and IAM roles. Save outputs `github_actions_ecr_role_arn`, `github_oidc_provider_arn`, and `velero_backup_bucket`.
4. **Prepare QA when ready.** Copy `terraform/environments/qa/terraform.tfvars.example` to `terraform.tfvars`. Set your trusted API CIDR and set `github_oidc_provider_arn` from dev's output. The QA network is `10.1.0.0/16`; verify it doesn't overlap VPN/peered networks. From `terraform/environments/qa`, run `terraform init`, then review `terraform plan` before `terraform apply`. QA creates its own cluster, ECR repos, backup bucket, and publisher role, but reuses the account's OIDC provider.
5. **Set GitHub variables.** Add Actions variables `AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_QA` from each environment's `terraform output -raw github_actions_ecr_role_arn`. Ensure the `GITHUB_TOKEN` can create pull requests and protect `develop`. The workflow file must also exist on GitHub's default branch for the **Run workflow** button to appear; when dispatching, select branch `develop`. Do not add AWS access keys.
6. **Test code.** Open a PR to `develop` or push app changes to `develop`. Gitleaks runs, and CI tests/builds/scans the Python, Java, and NGINX apps and lints/renders both chart value sets. Normal pushes do **not** publish images.
7. **Manually promote an image.** In GitHub Actions, select this workflow and choose **Run workflow**. Select branch `develop`, then choose app and target `dev` or `qa`. CI tests first; the publish job assumes that environment's OIDC role, pushes the commit-SHA image to its ECR repository, and opens a PR updating `helm/apps/<app>/values.yaml` for dev or `values-qa.yaml` for QA. Review and merge the PR; merging is the GitOps approval that changes desired state.
8. **Prepare and bootstrap Argo CD GitOps per cluster.** Read `terraform output -raw velero_backup_bucket` from the matching environment and replace the `REPLACE_WITH_AWS_ACCOUNT_ID` bucket placeholder in `platform/addons/dev/velero/values.yaml` or `platform/addons/qa/velero/values.yaml` before committing the GitOps change. Review cluster names and region values in the other add-on values files if you changed Terraform defaults. For a new cluster, install Argo CD outside Terraform first: run `helm repo add argo https://argoproj.github.io/argo-helm`, then `helm upgrade --install argocd argo/argo-cd --version 10.9.2 --namespace argocd --create-namespace --wait`. Skip installation if Argo CD is already running. Then set kubectl to the intended cluster context and apply `platform/argocd/root.yaml` for dev or `platform/argocd/qa-root.yaml` for QA. Each root loads only `application.yaml` files beneath its environment's `platform/addons/` and `platform/apps/` directories; chart values remain alongside each add-on Application and are read from Git. Velero is intentionally manual-sync until its bucket is configured. Update repository URL/branch references if you fork the repo.
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

Each platform component is organized under `platform/addons/<environment>/<addon>/`; chart-backed components have `application.yaml` and a sibling `values.yaml`. Sample workloads are separated under `platform/apps/<environment>/<app>/application.yaml`. The Argo CD roots combine both directories and include only `application.yaml`, so values files are not treated as Kubernetes manifests. The Helm releases were not applied, so no `removed` state blocks are needed. If a previous Terraform state does contain any of those releases, review the plan carefully: removing their resource declarations will plan to uninstall them. The sample application charts live in `helm/apps/`.

The add-on Applications currently fetch version-pinned charts from public Helm repositories, so Argo CD needs outbound access to those repositories. For a production private-network setup, mirror the pinned chart artifacts to an approved internal OCI/Helm registry and change the corresponding `repoURL` values before syncing.

Argo CD Applications currently reference external chart repositories and registries. For production, mirror and scan approved charts and images into a controlled private registry, pin immutable chart versions and image digests, and give Argo CD narrowly scoped read credentials. Vendored chart archives in Git improve availability but add repository size and a chart update process; they do not address images pulled from public registries.

If a prior Terraform apply did install any of these Helm releases, inspect the plan before applying: Terraform may propose uninstalling them now that the `helm_release` declarations have been removed. In that case, establish Argo CD ownership before accepting the destroy plan.

A custom domain and public HTTPS endpoint are not required. These applications use in-cluster Kubernetes Services; no Ingress or public LoadBalancer is configured for Argo CD, Grafana, Tempo, or the OpenTelemetry Collector. Use `kubectl port-forward` for local access during the demo. The AWS Load Balancer Controller being installed does not create an Internet-facing endpoint by itself.

### Terraform environment roots

Each directory under `terraform/environments/` is a separate Terraform root and state. `backend.tf` declares the S3 bucket, region, and environment-specific key; backend configuration cannot read tfvars or data sources. The checked-in `backend.config.hcl` files are comments only and do not override `backend.tf`. Local `terraform.tfvars` files supply ordinary Terraform variables and are git-ignored; their `.example` files are committed. QA has its own cluster, ECR repositories, Velero bucket, Argo CD Applications, chart values, and Karpenter resources. It reuses the one account-wide GitHub OIDC provider created by dev.

Image promotion is intentionally manual. `workflow_dispatch` requires choosing an app and environment and must be run from `develop`; it creates a PR after pushing to that environment's ECR. Configure GitHub Actions variables `AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_QA` using each Terraform root's `github_actions_ecr_role_arn` output. The PR merge—not the workflow run by itself—is what updates Git's desired image tag and allows Argo CD to deploy it.
