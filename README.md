Production-style Amazon EKS platform built with Terraform, GitHub Actions, ArgoCD, Helm, Karpenter, Velero, AWS Secrets Manager, Prometheus, Grafana, and OpenTelemetry.

## Architecture

GitHub
  │
  ▼
GitHub Actions
  │
  ├── Test
  ├── Docker Build
  ├── Security Scan
  └── Push Image
          │
          ▼
        Amazon ECR
          │
          ▼
        ArgoCD
          │
          ▼
        Amazon EKS
          │
    ┌─────┼───────────────┐
    │     │               │
 Karpenter Secrets      Observability
    │     │               │
    │     ▼               ├── Prometheus
    │  Secrets Manager    ├── Grafana
    │                     └── OpenTelemetry
    │
    └── Dynamic EC2 capacity

EKS
 │
 └── Velero
       │
       ▼
      S3

## Repository Structure

```text
.github/workflows/   CI/CD workflows
app/                 Application source
terraform/           AWS infrastructure
helm/                Application Helm chart
argocd/              GitOps configuration
platform/            Kubernetes platform components
docs/                Documentation