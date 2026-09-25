Terraform-provisioned Amazon EKS platform demo with Python Flask, Java/Maven, and NGINX sample applications, GitHub Actions CI, Amazon ECR, Argo CD, Karpenter, Prometheus/Grafana, OpenTelemetry/Tempo, Velero, and AWS Secrets Manager.

## Architecture

GitHub Actions scans repository history for secrets with Gitleaks, tests each application, builds its app-local Dockerfile, and scans images on PRs. On pushes to `main`, it assumes a tightly scoped AWS role via GitHub OIDC, publishes immutable SHA-tagged images to per-app ECR repositories, then opens GitOps image-promotion PRs. After those PRs merge, Argo CD deploys the images.

Terraform provisions VPC, EKS, ECR, IAM, S3, and foundational Helm releases. Argo CD reconciles Kubernetes add-ons and the sample apps from `platform/`.

## Repository Structure

```text
terraform/
  bootstrap/                 Terraform state bucket
  environments/dev/           EKS composition, AWS add-ons, Helm, outputs
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
platform/
  argocd/root.yaml            App-of-apps bootstrap
  argocd/apps/                Argo CD Applications (charts and GitOps)
  karpenter/                  EC2NodeClass and NodePools
  secrets/                    External Secrets store and demo secret
  apps/<name>/                Per-app Kubernetes Deployment and Service
README.md
```

## Platform Add-ons: Current State

| Component | Installation/ownership | Status |
|---|---|---|
| EKS, VPC, EBS CSI, AWS Load Balancer Controller | Terraform | Configured |
| Argo CD | Terraform Helm release | Configured; bootstraps `platform/argocd/root.yaml` |
| Karpenter controller and AWS IAM/Pod Identity | Terraform | Configured |
| Karpenter EC2NodeClass and NodePools | Argo CD | Configured after Terraform installs controller CRDs |
| Prometheus, Grafana, Alertmanager | Terraform Helm release | Configured |
| Tempo and OpenTelemetry Collector | Argo CD Helm applications | Configured; OTLP traces, metrics, and logs pipeline |
| AWS Secrets Manager | Terraform Pod Identity + External Secrets Operator | Configured; secret values remain in AWS |
| Velero and S3 backup bucket | Terraform S3/IAM + Argo CD Helm application | Configured; Kopia file-system backups, no EBS snapshots |
| ECR and GitHub Actions publishing role | Terraform | Configured; per-app repositories, GitHub OIDC, immutable image tags |
| Python, Java, and NGINX samples | Flask, Java 21/Maven, NGINX | Configured; separate build contexts and Kubernetes services |
| Application CI and image promotion | GitHub Actions | Test/build/scan matrix, publish to ECR, open per-app GitOps promotion PRs |
| HashiCorp Vault | — | Not installed; see note below |

### Deploy

1. Confirm `github_repository` in `terraform/environments/dev/variables.tf` is your actual GitHub `owner/repository`. AWS supports one GitHub Actions OIDC provider URL per account. If it already exists, import it to this state before applying: `terraform import module.container_registry.aws_iam_openid_connect_provider.github arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`.
2. From `terraform/environments/dev`, run `terraform init`, inspect `terraform plan`, then `terraform apply`. Terraform creates EKS, three ECR repositories, the GitHub OIDC role, Argo CD, Karpenter, the Velero bucket, and Pod Identity roles. Outputs include `sample_app_ecr_repositories` and `github_actions_ecr_role_arn`. If Registry requests time out, check DNS/proxy access to `registry.terraform.io` and retry.
3. In GitHub repository settings, add the Actions **variable** `AWS_ROLE_ARN` with the value of `terraform output -raw github_actions_ecr_role_arn`. No AWS access keys are needed. Ensure Actions are allowed to create pull requests and the `GITHUB_TOKEN` has repository contents and pull-request write permissions. Protect `main`; review and merge each image promotion PR.
4. Push changes under `apps/` to `main`. Actions tests, builds, and scans the Python, Java, and NGINX matrix; the publish job pushes immutable commit-SHA images to all three ECR repositories and creates per-app PRs updating `platform/apps/<app>/deployment.yaml`. Review and merge the PRs to promote images.
5. Apply `platform/argocd/root.yaml` to the cluster. Argo CD begins reconciling platform add-ons and the three sample apps using the images pinned in Git. Update the repository URL and branch in the Argo CD Application manifests if you fork or rename this repo.
6. To exercise External Secrets, create AWS Secrets Manager secret `eks-platform-demo/dev/demo-app` in `ap-south-1` with JSON fields `username` and `password`. Never put secret values in Git.

The Python and Java samples emit OpenTelemetry traces to `opentelemetry-collector.monitoring.svc.cluster.local:4317` (gRPC); the NGINX sample serves a static page. Traces are sent to Tempo; Grafana has Tempo configured as a data source. No custom domain or public HTTPS endpoint is required.

The Argo CD root uses automated sync/prune. Review the applications and IAM scope before using this pattern outside a disposable demo account. The S3 backup bucket has Terraform deletion protection.

### Vault decision

This demo uses AWS Secrets Manager as the source of truth and External Secrets Operator to sync selected values into Kubernetes. Vault would duplicate that role and requires decisions about storage, TLS, initialization/unseal, authentication, backup, and upgrade ownership. It is intentionally not installed by default. Do not use Vault dev mode or commit root/unseal credentials.

### Known follow-up

Velero currently backs up Kubernetes resources and file-system data through its node agent; EBS CSI snapshots are disabled. Snapshot-based PV restore needs the CSI snapshot controller/CRDs, AWS snapshot permissions/location, and a tested restore procedure. Terraform CI/plan validation and a Vault deployment are also not included.

### Deployment locations and access

Terraform-managed Helm releases are centralized in `terraform/environments/dev/helm.tf`. Helm charts managed by GitOps are centralized as Argo CD Application manifests in `platform/argocd/apps/`; the Terraform bootstrap of Argo CD remains in the environment Helm file so Argo CD can start before it manages other applications. `terraform/environments/dev/outputs.tf` contains environment outputs.

A custom domain and public HTTPS endpoint are not required. These applications use in-cluster Kubernetes Services; no Ingress or public LoadBalancer is configured for Argo CD, Grafana, Tempo, or the OpenTelemetry Collector. Use `kubectl port-forward` for local access during the demo. The AWS Load Balancer Controller being installed does not create an Internet-facing endpoint by itself.