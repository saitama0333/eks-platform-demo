# EKS platform demo

This project deploys three sample applications—Python, Java, and NGINX—to
Amazon EKS. Terraform creates the VPC, EKS cluster, ECR repositories and AWS
roles. Argo CD reads the Kubernetes and Helm configuration from the `develop`
branch and keeps the cluster in sync with Git.

Dev and QA have separate clusters, ECR repositories, Terraform state, and
Argo CD installations in AWS Account B. Both use Frankfurt (`eu-central-1`).
The existing `tf-gitops-nikhil` S3 bucket holds Terraform state and Velero
backups and must also be in Account B. The domain registration and authoritative
Route 53 hosted zone remain in Account A; Terraform does not create or change
the domain, hosted zone, or DNS records.

## Requirements

Install and configure:

- AWS CLI with access to AWS Account B
- Git Bash, Git, Terraform, `kubectl`, and Helm
- Docker Desktop, if building images on your computer

Run the commands below from the repository root in Git Bash unless a step says
otherwise. Replace `sandbox3` with an AWS CLI profile authenticated to Account
B. Do not use Account A credentials for Terraform.

## 1. Deploy dev

### Configure Terraform

Sign in and confirm the AWS account and the existing Terraform state bucket:

```bash
aws sso login --profile sandbox3
export AWS_PROFILE=sandbox3
aws sts get-caller-identity
aws s3api head-bucket --bucket tf-gitops-nikhil --region eu-central-1
```

Confirm that the `Account` returned by STS is the 12-digit Account B ID, and
that the existing `tf-gitops-nikhil` bucket is owned by Account B and accessible
for state and backups. The AWS provider is configured to reject credentials
for any account other than the `aws_account_id` supplied below; this guard
does not verify ownership of the separately configured S3 backend bucket.
The separate `terraform/bootstrap` configuration creates a differently named
`eks-platform-demo-tfstate-<account-id>` bucket, not `tf-gitops-nikhil`; it is
not needed when the documented backend bucket already exists. If you run the
bootstrap separately, set its `aws_account_id` to Account B as well.

`terraform.tfvars.example` is the version-controlled template; copy it once to
the ignored, machine-local `terraform.tfvars` and edit that copy. Keeping both
is intentional: the example documents required inputs without committing
workstation IPs or other environment-specific values. Never replace an existing
`terraform.tfvars` blindly; merge the required values into it.

```bash
cp terraform/environments/dev/terraform.tfvars.example \
  terraform/environments/dev/terraform.tfvars
```

The AWS account ID is `829647177071`. Add or update `aws_account_id` to that
value in an existing local file, keeping its other settings.

The example already sets `aws_account_id` to `829647177071`. Set
`cluster_endpoint_public_access_cidrs` to your trusted public IP in `/32`
format. Dev creates the account-level GitHub OIDC provider in Account B, so keep
`create_github_oidc_provider = true` and `github_oidc_provider_arn = null`.
Do not commit `terraform.tfvars`.

### Create the dev cluster and ECR repositories

```bash
cd terraform/environments/dev
terraform init -reconfigure
terraform plan -out=tfplan
terraform show tfplan
```

The backend now points to `tf-gitops-nikhil` at `dev/terraform.tfstate`.
`-reconfigure` selects this backend; it does not migrate state from another
bucket. If this environment already has state in a different bucket, stop and
plan a state migration before running a plan or apply. For a fresh deployment,
confirm the target backend bucket and key are correct before continuing.

Check that the plan is for the correct account, Frankfurt region, and dev
resources. Apply only after reviewing it:

```bash
terraform apply tfplan
terraform output -raw dev_ingress_nlb_dns_name \
  | tee ../../../dev-ingress-nlb-dns-name.txt
terraform output -raw vpc_id
terraform output sample_app_ecr_repositories
terraform output -raw github_actions_ecr_role_arn
terraform output -raw github_oidc_provider_arn
cd ../../..
```

Terraform creates the ECR repositories and the public dev ingress NLB, but it
does not build or push app images. The command also saves the NLB DNS name to
`dev-ingress-nlb-dns-name.txt` in the repository root. Verify the AWS account
ID in each `helm/apps/*/values-dev.yaml` ECR image URI matches Account B; if it
does not, build and publish the images using Account B before deploying.

### Configure DNS in Account A

GoDaddy should delegate `appledore.in` to the name servers of the authoritative
Route 53 hosted zone in Account A. Create the following CNAME records in that
hosted zone (not in Account B); both values are the NLB DNS name saved above:

| Record name | Type | Value |
| --- | --- | --- |
| `dev` | CNAME | Account B's dev ingress NLB DNS name |
| `*.dev` | CNAME | Account B's dev ingress NLB DNS name |

The wildcard record covers one-label hostnames such as `argocd.dev`,
`grafana.dev`, `prometheus.dev`, and `alertmanager.dev`. Leave the GoDaddy
nameserver delegation pointed at Account A's hosted zone. Terraform does not
provision cross-account DNS records or change the GoDaddy delegation. Confirm
the delegation and both CNAMEs resolve publicly before expecting the URLs to
work.

Save the OIDC provider ARN for QA. If using GitHub Actions to publish images,
add the dev role ARN as the repository variable `AWS_ROLE_ARN_DEV`.

### Build and publish dev images

With Docker Desktop running and access to the public base-image registries,
run the script from the repository root:

```bash
cd apps
bash image.sh dev
cd ..
```

The script builds all three apps, pushes them to the dev ECR repositories,
and updates `helm/apps/<app>/values-dev.yaml` with the ECR URI and tag. Review
the changes:

```bash
git diff -- helm/apps
```

Before pushing the ingress configuration, replace the fail-closed
`127.0.0.1/32` source-range annotations in `helm/argocd/values.yaml` and
`platform/addons/dev/prometheus/values.yaml` with the public egress CIDRs
allowed to access the admin tools. You can use the trusted workstation/VPN
egress CIDRs configured for the EKS API. Do not replace them with
`0.0.0.0/0`. The sample app at `dev.appledore.in` stays public; Argo CD,
Grafana, Prometheus, and Alertmanager are restricted to those CIDRs.
The ACME contact email is optional. No paid `appledore.in` mailbox is needed:
if you want expiry and account notices, add an email address you already
control to the `email` field in
`platform/addons/dev/cert-manager-issuer/resources/cluster-issuer.yaml`.

Terraform's `vpc_id` output is the source of truth for the cluster VPC. The AWS
Load Balancer Controller requires that ID as a top-level `vpcId` in
`platform/addons/dev/aws-load-balancer-controller/values.yaml`. After applying
Terraform, get it with:

```bash
terraform -chdir=terraform/environments/dev output -raw vpc_id
```

Update the values file if it differs. For QA, use
`terraform -chdir=terraform/environments/qa output -raw vpc_id` and update
`platform/addons/qa/aws-load-balancer-controller/values.yaml` instead. These
values are committed as ordinary per-cluster GitOps configuration; Argo CD
reads the repository and does not read Terraform state directly. Keep `vpcId`
at the root of each values file, not under `serviceAccount`.

Commit and push the configuration to `develop`; Argo CD reads that branch:

```bash
git add terraform/environments/dev/main.tf terraform/environments/dev/outputs.tf \
  terraform/environments/dev/providers.tf terraform/environments/dev/variables.tf \
  terraform/environments/dev/terraform.tfvars.example \
  terraform/environments/qa/providers.tf terraform/environments/qa/variables.tf \
  terraform/environments/qa/outputs.tf \
  terraform/environments/qa/terraform.tfvars.example \
  terraform/bootstrap/providers.tf terraform/bootstrap/variables.tf \
  terraform/modules/nlb terraform/modules/eks/main.tf \
  terraform/modules/eks/outputs.tf helm/argocd/values.yaml \
  helm/apps/*/values-dev.yaml helm/apps/nginx-demo/templates/ingress.yaml \
  platform/addons/dev/cert-manager \
  platform/addons/dev/cert-manager-issuer \
  platform/addons/dev/aws-load-balancer-controller \
  platform/addons/dev/ingress-nginx \
  platform/addons/dev/prometheus/values.yaml README.md
git commit -m "Add dev TLS ingress and tool access"
git push origin develop
```

If your computer cannot pull a public base image, use the GitHub Actions
method below instead. Do not publish the same app/tag using both methods.

### Install Argo CD and apply the dev root

Connect `kubectl` to the dev cluster:

```bash
aws eks update-kubeconfig --region eu-central-1  --name eks-platform-demo-dev --alias dev
kubectl config use-context dev
```

Install or upgrade Argo CD with the pinned Helm chart and the repository
values. Chart `10.10.5` packages Argo CD `v3.5.5`:

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update
helm upgrade --install argocd argo/argo-cd --version 10.10.5 \
  --namespace argocd --create-namespace --wait --kube-context dev \
  --values helm/argocd/values.yaml
```

This Helm release runs Argo CD in the cluster, including the server,
application controller, repo-server, Redis, Dex, ApplicationSet controller,
and notifications controller. Dex is not connected to an identity provider in
this demo, so SSO is not configured.

After the image values are pushed to `develop`, apply the root Application:

```bash
kubectl --context dev apply -f platform/argocd/dev-root.yaml
kubectl --context dev -n argocd get applications
kubectl --context dev get pods -A
```

The root discovers the dev Applications under `platform/addons/dev/` and
`platform/apps/dev/`. Argo CD then installs the pinned add-on charts and app
charts from Git. Do not manually run Helm installs for add-ons managed by
Argo CD.

Once DNS resolves, open `https://dev.appledore.in` for the sample app and
`https://argocd.dev.appledore.in`, `https://grafana.dev.appledore.in`,
`https://prometheus.dev.appledore.in`, and
`https://alertmanager.dev.appledore.in` for the tools. All five names resolve
through the CNAMEs in Account A to the public NLB in Account B. The NLB forwards
TCP ports 80 and 443 to the ingress-nginx NodePorts on the EKS nodes. The
ingress controller uses the requested hostname to route to the NGINX sample
app, Argo CD, Grafana, Prometheus, or Alertmanager service in the cluster.

The Argo CD hostname is `argocd.dev.appledore.in`, exactly as configured in
`helm/argocd/values.yaml`. `argocd.appledore.in` is a different hostname; a DNS
record pointing it at the same NLB does not add an Ingress rule or certificate
for that name. To use the shorter hostname, change the Argo CD Ingress hostname
and TLS host in `helm/argocd/values.yaml` and create an `argocd` CNAME to the
NLB in Account A. Argo CD is also restricted by the source-IP allowlist in
that values file. Update the allowlist to your current trusted public egress
CIDR if needed. The ingress controller must preserve the client IP for these
allowlists to work; its Service uses `externalTrafficPolicy: Local`. The sample
app has no such restriction, so it can work while an admin URL is blocked.

TLS is terminated by ingress-nginx, not by the NLB. Cert-manager obtains and
renews certificates for the configured hosts from Let's Encrypt using HTTP-01;
the public DNS records and inbound HTTP port 80 must remain reachable for
issuance and renewal. The wildcard DNS record does not itself provide a
wildcard TLS certificate. The sample app is public. Argo CD, Grafana,
Prometheus, and Alertmanager remain inaccessible until their fail-closed
`127.0.0.1/32` source allowlists are replaced with the intended trusted public
egress CIDRs. OTEL ingestion stays cluster-internal because the collector is an
API endpoint rather than a web UI.

This is a dev-grade, single-cluster setup, not a production-ready platform.
The admin tools are protected by source-IP allowlists, not SSO; access is
denied until the placeholder CIDRs are replaced. Tempo is accessed from
Grafana and is not separately exposed. Review node-group scaling, backups and
restore procedures, monitoring/alerting, security updates, and a real identity
provider before production use. High availability and disaster recovery are
not included in this initial setup.

## 2. Add QA

Keep dev in place. QA uses a separate VPC, EKS cluster, ECR repositories,
Terraform state key, and Argo CD installation. It reuses the account-level
GitHub OIDC provider created by dev.

### Configure and create QA

Copy the QA example file:

```bash
cp terraform/environments/qa/terraform.tfvars.example \
  terraform/environments/qa/terraform.tfvars
```

Set the trusted public IP in `cluster_endpoint_public_access_cidrs`. Replace
`REPLACE_WITH_DEV_GITHUB_OIDC_PROVIDER_ARN` with the ARN saved from dev, and
keep `create_github_oidc_provider = false`. Set `aws_account_id` to the same
Account B ID used for dev. Do not commit `terraform.tfvars`.

Create the QA resources:

```bash
cd terraform/environments/qa
terraform init -reconfigure
terraform plan -out=tfplan
terraform show tfplan
```

QA uses the same bucket at `qa/terraform.tfstate`. As with dev,
`-reconfigure` does not migrate an existing state from another bucket; stop and
plan a migration first if QA already has state elsewhere.

Review the account, region, network, and planned QA resources before applying:

```bash
terraform apply tfplan
terraform output sample_app_ecr_repositories
terraform output -raw github_actions_ecr_role_arn
cd ../../..
```

If using GitHub Actions to publish QA images, set the repository variable
`AWS_ROLE_ARN_QA` to the QA role ARN.

### Publish QA images and deploy

For local publishing, from the repository root run:

```bash
cd apps
bash image.sh qa
cd ..
git diff -- helm/apps
git add helm/apps/*/values-qa.yaml
git commit -m "Update QA application images"
git push origin develop
```

Connect to QA, install Argo CD there, and apply the QA root:

```bash
aws eks update-kubeconfig --region eu-central-1 \
  --name eks-platform-demo-qa --alias qa
kubectl config use-context qa

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update
helm upgrade --install argocd argo/argo-cd --version 10.10.5 \
  --namespace argocd --create-namespace --wait --kube-context qa

kubectl --context qa apply -f platform/argocd/qa-root.yaml
kubectl --context qa -n argocd get applications
kubectl --context qa get pods -A
```

As with dev, ensure QA image values are committed to `develop` before applying
the root. Argo CD will install the QA add-ons and apps from
`platform/addons/qa/` and `platform/apps/qa/`.

## Destroy and recreate an environment

Each environment keeps Terraform state in the existing `tf-gitops-nikhil`
bucket: `dev/terraform.tfstate` or `qa/terraform.tfstate`. Destroying an
environment does not require deleting that bucket or its state object. Do not
delete the state object: Terraform needs it to track what it created. Keep the
ignored local `terraform.tfvars`; it contains the inputs needed for the next
apply.

Before destroying, account for these resources:

- The ECR repositories use `force_delete = false`. Destroy will fail while
  they contain images. Keep the repositories and images, or deliberately empty
  them before destroying the environment.
- The S3 bucket used for Terraform state and Velero backups is existing and
  is not created by either environment. It is not deleted by these roots.
- Dev creates the account-level GitHub OIDC provider used by QA. Destroying
  dev removes that provider and interrupts GitHub Actions role assumption for
  QA until dev is applied again. Reapply dev before running QA image publishing.

For dev, authenticate to Account B and destroy from the dev Terraform root:

```bash
aws sso login --profile sandbox3

terraform -chdir=terraform/environments/dev init -reconfigure
terraform -chdir=terraform/environments/dev plan -destroy -out=destroy.tfplan
terraform -chdir=terraform/environments/dev show destroy.tfplan
terraform -chdir=terraform/environments/dev apply destroy.tfplan
```

Use `terraform/environments/qa` for QA. Review the plan to confirm it targets
only the intended environment and Account B before applying it. Recreate with
the existing local inputs:

```bash
terraform -chdir=terraform/environments/dev init -reconfigure
terraform -chdir=terraform/environments/dev plan -out=tfplan
terraform -chdir=terraform/environments/dev show tfplan
terraform -chdir=terraform/environments/dev apply tfplan
```

Keep `aws_account_id`, region, cluster version, and VPC/subnet CIDRs consistent
with the intended setup. Change `cluster_endpoint_public_access_cidrs` in local
`terraform.tfvars` if your trusted public/VPN egress IP changed; use a CIDR
such as `x.x.x.x/32`, never `0.0.0.0/0`. Change VPC/subnet CIDRs only if they
overlap another connected network. QA must keep
`create_github_oidc_provider = false` and use the provider ARN output from dev.

After apply, get generated values instead of guessing them:

```bash
terraform -chdir=terraform/environments/dev output -raw vpc_id
terraform -chdir=terraform/environments/dev output -raw dev_ingress_nlb_dns_name
terraform -chdir=terraform/environments/dev output -raw github_oidc_provider_arn
terraform -chdir=terraform/environments/dev output -raw github_actions_ecr_role_arn
terraform -chdir=terraform/environments/dev output sample_app_ecr_repositories
```

If the VPC was recreated, update the top-level `vpcId` in
`platform/addons/dev/aws-load-balancer-controller/values.yaml`. If the NLB DNS
name changed, update the `dev` and `*.dev` CNAME records in Account A's
authoritative Route 53 zone. If your public egress IP changed, update the EKS
API CIDR in local `terraform.tfvars` and the admin Ingress allowlists in
`helm/argocd/values.yaml` and `platform/addons/dev/prometheus/values.yaml`.
Keep those allowlists restricted to trusted IPs. App image values only need
updating if the AWS account or ECR repository URLs changed. Commit and push
changed GitOps values to `develop`; Argo CD does not read Terraform outputs
directly. Repeat with QA outputs and QA values when recreating QA.

## GitHub Actions image publishing

The repository has a **GitHub Actions** workflow at
`.github/workflows/ci.yml`. There is no `.gitlab-ci.yml` in this project.

The workflow runs on pull requests and pushes to `develop`. It scans for
secrets, lints and renders the app Helm charts, runs the Python and Java
tests, builds app images, and scans those images for critical vulnerabilities.
Terraform plans and add-on Helm charts are not tested by this workflow.

To publish an image without building locally, run the
`applications-ci-and-publish` workflow manually from `develop`, choose one
app and `dev` or `qa`, and review and merge the promotion PR. It pushes the
image to ECR and updates that app's environment values. Configure
`AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_QA` as GitHub repository variables. The
workflow uses GitHub OIDC, not long-lived AWS access keys. Allow the
repository Actions token to create pull requests.

## Access the services

Run this from the repository root in Git Bash after connecting `kubectl` to
the cluster. The script starts the available port-forwards in the background:

```bash
bash scripts/port-forward.sh dev start
```

Use `qa` for the QA cluster. Open the URLs printed by the script, including
Argo CD, Grafana, Prometheus, Alertmanager, Tempo, OpenTelemetry, and the
sample apps. The OTEL and Velero endpoints are APIs/metrics, not dashboards.
Velero has no web UI in this project. Loki is not installed either; the
OpenTelemetry Collector currently writes logs to its debug exporter, so there
is no searchable or persistent log UI.

Check or stop the background forwards with:

```bash
bash scripts/port-forward.sh dev status
bash scripts/port-forward.sh dev stop
```

The script only binds to `127.0.0.1` on the computer where it runs. Port
forwards are local access, not public endpoints. If you run them on a remote
host over SSH, use SSH local forwarding to reach that host's localhost ports.

The Grafana password and initial Argo CD admin password are in Kubernetes
Secrets in their respective namespaces.

If public Argo CD ingress is unavailable, forward its HTTPS service port and
open the local URL (accept the certificate hostname warning for localhost):

```bash
kubectl --context dev -n argocd port-forward svc/argocd-server 8443:443
```

Then open `https://localhost:8443`. Keep the port-forward command running while
using the browser.

The Argo CD CLI can inspect and control an Application after `argocd login`:

```bash
argocd app get kube-prometheus-stack
argocd app terminate-op kube-prometheus-stack
argocd app get kube-prometheus-stack
argocd app sync kube-prometheus-stack
```

Terminate a stuck operation, confirm it is no longer `Running`, then sync it
again. Replace `kube-prometheus-stack` with the Application name shown by
`kubectl --context dev -n argocd get applications`.

For UI failures, check the response and the matching layer: `403` usually means
the Ingress source-IP allowlist rejected the request; `503` means the backend
Service has no ready endpoints. Check the current rules and endpoints with:

```bash
kubectl --context dev get ingress -A -o wide
kubectl --context dev -n monitoring get pods,svc,endpoints
kubectl --context dev get certificates -A
```

Wait for Grafana's certificate to become `Ready` before relying on browser TLS.
Let's Encrypt HTTP-01 validation needs public port 80 to reach the ingress
controller during issuance and renewal.

Prometheus, Grafana, Alertmanager, Tempo, and the Python demo use encrypted
gp3 persistent volumes. They survive pod restarts, but this setup does not
back up monitoring data or EBS volumes. The Velero schedule covers workloads
in the `default` namespace only.

## External Secrets sample

`platform/secrets/dev/demo-app-secret.yaml` tells External Secrets to read the
AWS Secrets Manager secret named `eks-platform-demo/dev/demo-app` in
`eu-central-1`, then copy its `username` and `password` properties into the
Kubernetes Secret `default/demo-app-secret`. The manifest does not create the
AWS secret or invent its values. A `Ready` ClusterSecretStore means the
controller can connect to AWS; it does not verify that the requested secret
name and JSON properties exist.

If you want this sample secret, create it in AWS Account B's Secrets Manager
in `eu-central-1` as a JSON secret with `username` and `password` keys. Keep
the actual values in Secrets Manager; never commit them to this repository.
QA uses `eks-platform-demo/qa/demo-app`. The ExternalSecret app remains
Degraded until its referenced AWS secret is supplied. No current workload in
this repository references `default/demo-app-secret`; if you do not plan to
use this sample, remove its ExternalSecret manifest from GitOps instead of
creating credentials that nothing uses.

## Bash aliases

Add these to `~/.bashrc` in Git Bash, then reload it with `source ~/.bashrc`:

```bash
alias tf='terraform'
alias tfi='terraform init'
alias tfv='terraform validate'
alias tfp='terraform plan'
alias tfo='terraform output'
alias tfdev='terraform -chdir=terraform/environments/dev'
alias tfqa='terraform -chdir=terraform/environments/qa'

alias k='kubectl'
alias kctx='kubectl config current-context'
alias kdev='kubectl --context dev'
alias kqa='kubectl --context qa'
alias kpods='kubectl get pods -A'
alias kapps='kubectl get applications -n argocd'

alias pfdev='bash scripts/port-forward.sh dev start'
alias pfqa='bash scripts/port-forward.sh qa start'
alias pfstopdev='bash scripts/port-forward.sh dev stop'
alias pfstopqa='bash scripts/port-forward.sh qa stop'

alias gs='git status --short'
alias gd='git diff'
```

For example, after adding these aliases, `tfdev plan` runs Terraform from the
dev environment directory and `kdev get pods -A` lists pods in dev.

## Useful paths

- Terraform: `terraform/environments/dev/` and `terraform/environments/qa/`
- Local app image script: `apps/image.sh`
- App charts and image values: `helm/apps/`
- Argo CD roots: `platform/argocd/`
- Add-on Applications and values: `platform/addons/<environment>/`
- GitHub Actions workflow: `.github/workflows/ci.yml`
- Local port forwards: `scripts/port-forward.sh`
