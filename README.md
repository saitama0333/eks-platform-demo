# EKS platform demo

This project deploys three sample applications—Python, Java, and NGINX—to
Amazon EKS. Terraform creates the VPC, EKS cluster, ECR repositories and AWS
roles. Argo CD reads the Kubernetes and Helm configuration from the `develop`
branch and keeps the cluster in sync with Git.

Dev and QA have separate clusters, ECR repositories, Terraform state, and
Argo CD installations. Both use Frankfurt (`eu-central-1`). The Terraform
state and Velero backups use an existing S3 bucket, `appledore-gitops`.

## Requirements

Install and configure:

- AWS CLI with access to the intended AWS account
- Git Bash, Git, Terraform, `kubectl`, and Helm
- Docker Desktop, if building images on your computer

Run the commands below from the repository root in Git Bash unless a step says
otherwise. Replace `sandbox3` with your AWS CLI profile.

## 1. Deploy dev

### Configure Terraform

Sign in and confirm the AWS account and the existing Terraform state bucket:

```bash
aws sso login --profile sandbox3
export AWS_PROFILE=sandbox3
aws sts get-caller-identity
aws s3api head-bucket --bucket appledore-gitops --region eu-central-1
```

Copy the dev example file and edit the local copy:

```bash
cp terraform/environments/dev/terraform.tfvars.example \
  terraform/environments/dev/terraform.tfvars
```

Set `cluster_endpoint_public_access_cidrs` to your trusted public IP in `/32`
format. Dev creates the account-level GitHub OIDC provider, so keep
`create_github_oidc_provider = true` and `github_oidc_provider_arn = null`.
Do not commit `terraform.tfvars`.

### Create the dev cluster and ECR repositories

```bash
cd terraform/environments/dev
terraform init
terraform plan -out=tfplan
terraform show tfplan
```

Check that the plan is for the correct account, Frankfurt region, and dev
resources. Apply only after reviewing it:

```bash
terraform apply tfplan
terraform output -raw dev_ingress_nlb_dns_name \
  | tee ../../../dev-ingress-nlb-dns-name.txt
terraform output sample_app_ecr_repositories
terraform output -raw github_actions_ecr_role_arn
terraform output -raw github_oidc_provider_arn
cd ../../..
```

Terraform creates the ECR repositories and the public dev ingress NLB, but it
does not build or push app images. The command also saves the NLB DNS name to
`dev-ingress-nlb-dns-name.txt` in the repository root. In Account A, create
CNAME records for `dev.appledore.in` and `*.dev.appledore.in`, both pointing
to that NLB DNS name. Save the OIDC provider ARN for QA. If using GitHub
Actions to publish images, add the dev role ARN as the repository variable
`AWS_ROLE_ARN_DEV`.

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

Commit and push the configuration to `develop`; Argo CD reads that branch:

```bash
git add terraform/environments/dev/main.tf terraform/environments/dev/outputs.tf \
  terraform/modules/nlb terraform/modules/eks/main.tf \
  terraform/modules/eks/outputs.tf helm/argocd/values.yaml \
  helm/apps/*/values-dev.yaml helm/apps/nginx-demo/templates/ingress.yaml \
  platform/addons/dev/cert-manager \
  platform/addons/dev/cert-manager-issuer \
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
aws eks update-kubeconfig --region eu-central-1 \
  --name eks-platform-demo-dev --alias dev
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
`https://alertmanager.dev.appledore.in` for the tools. Cert-manager obtains
and renews individual Let's Encrypt certificates using HTTP-01. The DNS owner
must keep the two CNAME records in place. OTEL ingestion stays cluster-internal
because the collector is an API endpoint rather than a web UI.

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
keep `create_github_oidc_provider = false`. Do not commit `terraform.tfvars`.

Create the QA resources:

```bash
cd terraform/environments/qa
terraform init
terraform plan -out=tfplan
terraform show tfplan
```

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

Prometheus, Grafana, Alertmanager, Tempo, and the Python demo use encrypted
gp3 persistent volumes. They survive pod restarts, but this setup does not
back up monitoring data or EBS volumes. The Velero schedule covers workloads
in the `default` namespace only.

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
