# Deployment runbook

This guide covers the usual steps to create, update, pause, resume, and remove
the dev and QA environments. For component roles and architecture, see
[`ARCHITECTURE.md`](ARCHITECTURE.md).

Run commands from the repository root in Git Bash unless stated otherwise.
Use AWS Account B credentials for Terraform and EKS. The Route 53 hosted zone
and domain delegation are in Account A.

## Before you start

You need Git Bash, Git, AWS CLI, Terraform, `kubectl`, Helm, and Docker Desktop
for local image builds. Sign in to Account B and set the profile:

```bash
aws sso login --profile sandbox3
export AWS_PROFILE=sandbox3
aws sts get-caller-identity
```

Confirm the returned account is `829647177071`. Do not commit local
`terraform.tfvars` files or credentials.

## Create or update dev

### 1. Configure and apply Terraform

Copy the example only if the local file does not already exist. Set your
trusted public/VPN egress IP in `cluster_endpoint_public_access_cidrs` as a
`/32`; keep the other existing values when updating an existing setup.

```bash
[[ -f terraform/environments/dev/terraform.tfvars ]] || \
  cp terraform/environments/dev/terraform.tfvars.example \
    terraform/environments/dev/terraform.tfvars
```

Review the plan before applying:

```bash
terraform -chdir=terraform/environments/dev init -reconfigure
terraform -chdir=terraform/environments/dev plan -out=tfplan
terraform -chdir=terraform/environments/dev show tfplan
terraform -chdir=terraform/environments/dev apply tfplan
```

The backend uses the existing `tf-gitops-nikhil` bucket and key
`dev/terraform.tfstate`. `-reconfigure` selects that backend; it does not
migrate state. If this environment already has state in a different backend,
stop and plan a state migration before proceeding. Never delete the S3 state.

EKS add-on versions are pinned in
`terraform/environments/dev/variables.tf`. A plan that shows add-on version
changes is aligning the cluster with those pins. Update the pins deliberately
when upgrading; the project does not select a new build on every plan. Review
the Terraform plan before applying.

After Terraform completes, check the core add-ons and nodes:

```bash
aws eks list-addons --profile sandbox3 --cluster-name eks-platform-demo-dev --region eu-central-1
aws eks list-nodegroups --profile sandbox3 --cluster-name eks-platform-demo-dev --region eu-central-1
aws eks update-kubeconfig --profile sandbox3 --name eks-platform-demo-dev --region eu-central-1 --alias dev
kubectl --context dev get nodes -o wide
```

The nodes should be `Ready`; the add-on list should include `vpc-cni`,
`coredns`, and `kube-proxy`. Resolve any node or CNI issue before installing
cluster workloads. Confirm the `vpc_id` output matches the top-level `vpcId`
in `platform/addons/dev/aws-load-balancer-controller/values.yaml`. Save the
`github_oidc_provider_arn` output; QA reuses it.

### 2. Build and publish application images

With Docker Desktop running, build and push the dev images from the repository
root:

```bash
cd apps
bash image.sh dev
cd ..
git diff -- helm/apps
```

Review and commit the updated dev image values, then push them to `develop`.
Argo CD deploys from that branch. For automated publishing, use the GitHub
Actions or GitLab CI flow described in the
[CI section](#publish-images-with-ci).

### 3. Install Argo CD and apply the root

Argo CD itself is bootstrapped with Helm. Platform add-ons and applications
after that are managed by Argo CD from Git; do not install those charts
manually.

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update
helm upgrade --install argocd argo/argo-cd --version 10.10.5 \
  --namespace argocd --create-namespace --wait --kube-context dev \
  --values helm/argocd/values.yaml --set server.ingress.enabled=false

kubectl --context dev apply -f platform/argocd/dev-root.yaml
kubectl --context dev -n argocd get applications
```

Wait for the Applications and workloads to become Synced and Healthy:

```bash
kubectl --context dev -n argocd get applications
kubectl --context dev get pods -A
```

The first Argo CD install keeps its Ingress disabled. Enable it only after
ingress-nginx, its admission Service and the `nginx` IngressClass are ready,
and the `letsencrypt-prod` ClusterIssuer exists:

```bash
kubectl --context dev -n ingress-nginx get svc,daemonset,pods
kubectl --context dev get ingressclass nginx
kubectl --context dev get clusterissuer letsencrypt-prod
helm upgrade argocd argo/argo-cd --version 10.10.5 \
  --namespace argocd --wait --kube-context dev \
  --values helm/argocd/values.yaml
```

This avoids starting HTTP-01 certificate checks before the ingress controller
can serve them.

### 4. Point DNS and verify HTTPS

Terraform creates the dev NLB in Account B. In Account A's authoritative
Route 53 hosted zone, point the dev names to that NLB:

| Name | Record | Target |
| --- | --- | --- |
| `dev.appledore.in` | CNAME | Dev ingress NLB DNS name |
| `*.dev.appledore.in` | CNAME | Dev ingress NLB DNS name |
| `appledore.in` | A Alias | Dev ingress NLB and its canonical hosted zone ID |
| `www.appledore.in` | CNAME | Dev ingress NLB DNS name |

Get the current NLB values from Terraform instead of copying an old name:

```bash
terraform -chdir=terraform/environments/dev output -raw dev_ingress_nlb_dns_name
terraform -chdir=terraform/environments/dev output -raw dev_ingress_nlb_canonical_zone_id
```

Wait for the Ingresses and certificates to become ready. The sample app is
public; Argo CD, Grafana, Prometheus, and Alertmanager use source-IP allowlists
from their values files. Update those allowlists when your trusted public
egress IP changes. The current hostnames are listed in
[`ARCHITECTURE.md`](ARCHITECTURE.md#public-hostnames-and-tls). A DNS record
alone does not create an Ingress route or TLS certificate for a hostname.

Quick checks:

```bash
kubectl --context dev get ingress -A
kubectl --context dev get certificates -A
kubectl --context dev -n ingress-nginx get svc,pods -o wide
```

## Publish images with CI

The repository supports GitHub Actions and GitLab CI. Both use OIDC to assume
an AWS role; do not add long-lived AWS keys to CI variables.

- **GitHub:** run the `applications-ci-and-publish` workflow from `develop`,
  select an app and environment, then review and merge the image-promotion PR.
  Configure `AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_QA` as repository variables.
- **GitLab:** configure the OIDC trust and required project variables, then
  start a pipeline on `develop` with `APP_NAME` and `TARGET_ENV`. Run the
  manual publish job and review the resulting merge request. See
  [`.gitlab/README.md`](../.gitlab/README.md).

After the image values are merged to `develop`, Argo CD deploys them.

## Add QA

QA has its own cluster, VPC, ECR repositories, Terraform state key, and Argo CD
installation. It uses the account-level GitHub OIDC provider created by dev.

1. Copy `terraform/environments/qa/terraform.tfvars.example` to
   `terraform/environments/qa/terraform.tfvars` if needed.
2. Set the trusted EKS API CIDR, Account B ID, and the dev GitHub OIDC provider
   ARN. Keep `create_github_oidc_provider = false`.
3. Plan and apply from the QA root:

   ```bash
   terraform -chdir=terraform/environments/qa init -reconfigure
   terraform -chdir=terraform/environments/qa plan -out=tfplan
   terraform -chdir=terraform/environments/qa show tfplan
   terraform -chdir=terraform/environments/qa apply tfplan
   ```

4. Publish QA images with `bash apps/image.sh qa` or the CI flow, and merge the
   resulting image-value changes to `develop`.
5. Connect to QA, install Argo CD with the same chart and values, then apply
   `platform/argocd/qa-root.yaml`:

   ```bash
   aws eks update-kubeconfig --profile sandbox3 --name eks-platform-demo-qa --region eu-central-1 --alias qa
   helm upgrade --install argocd argo/argo-cd --version 10.10.5 \
     --namespace argocd --create-namespace --wait --kube-context qa \
     --values helm/argocd/values.yaml
   kubectl --context qa apply -f platform/argocd/qa-root.yaml
   kubectl --context qa -n argocd get applications
   ```

QA state is stored at `qa/terraform.tfstate` in the existing backend bucket.
Do not reconfigure an environment that already has state elsewhere without
planning a migration.

## Pause and resume dev

Use the scripts for an overnight pause. They change the Git-managed workload
replicas and Karpenter limits, push a pause commit, then scale the managed node
group and Karpenter capacity to zero. The EKS control plane remains running.

```bash
export AWS_PROFILE=sandbox3
bash scripts/pause-dev.sh
```

Confirm the prompt with `PAUSE`. Keep the pause-state file in your user
profile; `resume-dev.sh` needs it to restore the original node-group settings
and revert the exact pause commit. Do not remove EC2 instances directly.

To restore dev:

```bash
export AWS_PROFILE=sandbox3
bash scripts/resume-dev.sh
```

The resume script restores core nodes first, waits for Argo CD, then reverts
the pause commit so workloads and Karpenter can start again. If either script
stops before its success message, read its last error and check the node-group
state before retrying; do not run two copies at the same time.

## Access and quick checks

Start local port-forwards from the repository root:

```bash
bash scripts/port-forward.sh dev start
bash scripts/port-forward.sh dev status
bash scripts/port-forward.sh dev stop
```

Use `qa` instead of `dev` for QA. The script prints the local URLs. These
forwards bind to localhost; they are not public endpoints.

Useful checks when something is not ready:

```bash
kubectl --context dev get nodes -o wide
kubectl --context dev -n argocd get applications
kubectl --context dev get pods -A
kubectl --context dev get ingress,certificates -A
kubectl --context dev -n monitoring get prometheusrules
```

For a stuck Argo CD operation, inspect the Application status and sync result
before terminating or retrying it. For public URL failures, check DNS, the
Ingress host rule, certificate readiness, source-IP allowlists, and backend
Service endpoints in that order.

The External Secrets demo is optional. Its manifest expects an AWS Secrets
Manager JSON secret named `eks-platform-demo/dev/demo-app` with `username` and
`password` properties. See
[`platform/secrets/dev/demo-app-secret.yaml`](../platform/secrets/dev/demo-app-secret.yaml).
No application currently uses this sample secret.

## Destroy or recreate an environment

Destroy only when you intend to remove the cluster and its Terraform-managed
infrastructure. First review the destroy plan. ECR repositories cannot be
deleted while they contain images (`force_delete = false`). The shared state
and Velero S3 bucket is existing infrastructure; do not delete it or its
state objects.

```bash
terraform -chdir=terraform/environments/dev init -reconfigure
terraform -chdir=terraform/environments/dev plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/environments/dev show destroy.tfplan
terraform -chdir=terraform/environments/dev apply destroy.tfplan
```

Use `terraform/environments/qa` for QA. Dev owns the account-level GitHub
OIDC provider used by QA; destroying dev interrupts QA GitHub image publishing
until dev is recreated. To recreate, keep the local `terraform.tfvars`, run
`init`, review a normal `plan`, then `apply`. Refresh the kubeconfig, DNS
targets, and AWS Load Balancer Controller `vpcId` from Terraform outputs if
the cluster or VPC was recreated. Argo CD does not read Terraform outputs
directly; commit any changed GitOps values to `develop`.
