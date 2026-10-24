# Deployment and operations runbook

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

Keep the AWS SSO session valid through the full apply. Afterward, verify the
cluster add-ons and nodes before installing Argo CD:

```bash
aws eks list-addons --cluster-name eks-platform-demo-dev --region eu-central-1
aws eks list-nodegroups --cluster-name eks-platform-demo-dev --region eu-central-1
kubectl --context dev get nodes -o wide
```

The add-on list should include `vpc-cni`, `coredns`, and `kube-proxy`, and
nodes should be `Ready`. If Terraform reports `ExpiredToken` or says it wrote
`errored.tfstate`, stop before another apply. Renew credentials and compare
`terraform state pull` with the errored state; only push a recovery state if it
is newer and verified. Never delete the S3 backend state.

### Pin and update EKS managed add-ons

Dev pins exact EKS add-on build versions in
`terraform/environments/dev/variables.tf` and passes them to the EKS module.
This keeps routine plans repeatable: Terraform will not automatically move to
each new AWS build. The pins are for Kubernetes `1.33`; review and update them
when changing `cluster_version` or when intentionally upgrading add-ons.

Use the EKS API to check available builds and Kubernetes compatibility before
changing the map. The `defaultVersion` flag identifies AWS's default build; it
is not necessarily the newest available build.

```bash
aws eks describe-addon-versions \
  --kubernetes-version 1.33 \
  --addon-name vpc-cni \
  --region eu-central-1 \
  --query 'addons[0].addonVersions[].{version:addonVersion,default:compatibilities[0].defaultVersion}' \
  --output table
```

Review the full Terraform plan before applying a version change. The shared EKS
module uses dynamic latest-compatible selection only when an environment does
not pass an explicit `addon_versions` map.

Terraform creates the ECR repositories and the public dev ingress NLB, but it
does not build or push app images. The command also saves the NLB DNS name to
`dev-ingress-nlb-dns-name.txt` in the repository root. Verify the AWS account
ID in each `helm/apps/*/values-dev.yaml` ECR image URI matches Account B; if it
does not, build and publish the images using Account B before deploying.

### Configure DNS in Account A

GoDaddy should delegate `appledore.in` to the name servers of the authoritative
Route 53 hosted zone in Account A. The dev subdomains use CNAME records. The
root name cannot use a CNAME, so create an A Alias to the NLB as well:

| Record name | Type | Value |
| --- | --- | --- |
| *(leave blank for root)* | A, Alias enabled | Account B's dev NLB in `eu-central-1` |
| `dev` | CNAME | Account B's dev ingress NLB DNS name |
| `*.dev` | CNAME | Account B's dev ingress NLB DNS name |

The wildcard record covers one-label hostnames such as `argocd.dev`,
`grafana.dev`, `prometheus.dev`, and `alertmanager.dev`. For the apex Alias,
the NLB's canonical hosted zone ID is different from the domain's Route 53
zone ID. Get the NLB DNS name and canonical zone ID from Terraform after the
next apply, or query AWS Account B:

```bash
aws --profile sandbox3 elbv2 describe-load-balancers \
  --names eks-platform-demo-dev-ingress --region eu-central-1 \
  --query 'LoadBalancers[0].{DNSName:DNSName,CanonicalZoneId:CanonicalHostedZoneId}'
```

In the Route 53 hosted zone in Account A, create an A record for the root,
turn on **Alias**, choose **Network Load Balancer**, region `eu-central-1`, and
enter Account B's NLB DNS name and canonical zone ID. AWS documents this
cross-account setup in [Route 53: routing traffic to an ELB load balancer](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-to-elb-load-balancer.html).
Keep the existing `www` CNAME to the NLB. Leave GoDaddy delegation pointed at
Account A's hosted zone. Terraform does not manage these cross-account DNS
records or the GoDaddy delegation.

The `www` CNAME already points to the dev NLB, and the apex A Alias has now
been added in Account A. Confirm both names resolve publicly. The working
Git changes add `appledore.in` and `www.appledore.in` as NGINX demo
Ingress/TLS hosts. Push and sync those changes, then wait for the Ingress and
certificate to become healthy before checking `https://appledore.in` and
`https://www.appledore.in`. If DNS resolves but NGINX returns 404, check that
the live Ingress has a rule for the requested host; DNS alone does not add an
Ingress route.

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

Before pushing ingress configuration, set the source-range annotations in
`helm/argocd/values.yaml` and `platform/addons/dev/prometheus/values.yaml` to
trusted public/VPN egress CIDRs for admin access. Keep them aligned with the
EKS API CIDR where practical; never use `0.0.0.0/0`. The demo app hosts
`dev.appledore.in`, `appledore.in`, and `www.appledore.in` are public; Argo CD,
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
helm upgrade --install argocd argo/argo-cd --version 10.10.5 --namespace argocd --create-namespace --wait --kube-context dev --values helm/argocd/values.yaml --set server.ingress.enabled=false
```

This Helm release runs Argo CD in the cluster, including the server,
application controller, repo-server, Redis, Dex, ApplicationSet controller,
and notifications controller. Dex is not connected to an identity provider in
this demo, so SSO is not configured.

This command is the **bootstrap step** for Argo CD: the cluster needs Argo CD
running before Argo CD can manage applications from Git. Pinning the chart
version and keeping its values file in Git makes the install repeatable. The
temporary `--set server.ingress.enabled=false` avoids exposing the UI before
ingress-nginx and cert-manager are ready; the next documented Helm upgrade
enables it. In a production pipeline, this bootstrap can be run by a controlled
deployment job with reviewed inputs and cluster credentials. Once Argo CD is
installed, use the Git-managed child Applications for add-ons and workloads;
avoid separate manual `helm upgrade` commands for those releases, since they
would compete with Argo CD.

After the image values are pushed to `develop`, apply the root Application:

```bash
kubectl --context dev apply -f platform/argocd/dev-root.yaml
kubectl --context dev -n argocd get applications
kubectl --context dev get pods -A
```

The root discovers the dev Applications under `platform/addons/dev/` and
`platform/apps/dev/`. Argo CD then installs the pinned add-on charts and app
charts from Git. Do not manually run Helm installs for add-ons managed by
Argo CD. The initial Argo CD install keeps its public Ingress disabled so
cert-manager cannot start HTTP-01 issuance before ingress-nginx and its
`nginx` IngressClass have been installed.

The AWS Load Balancer Controller configuration disables its Service mutator
webhook because this platform uses a Terraform-managed NLB and ingress-nginx
`NodePort` Services. Keep `enableServiceMutatorWebhook: false` in
`platform/addons/dev/aws-load-balancer-controller/values.yaml`.

Before testing public URLs, verify ingress-nginx has a ready NodePort Service
and controller pods:

```bash
kubectl --context dev -n ingress-nginx get svc,daemonset,pods -o wide
```

Expect the controller Service to expose `80:30080` and `443:30443`, with all
desired DaemonSet pods ready. Then confirm both NLB target groups are healthy.
If Argo CD is waiting for the DaemonSet after a Service admission error, fix
the AWS controller sync first, terminate the stale ingress-nginx operation,
and start a fresh sync. A sync waiting on an unhealthy DaemonSet may remain
`Running`; it does not mean the Service was created.

Before enabling the Argo CD Ingress, confirm these prerequisites are ready:

```bash
kubectl --context dev get ingressclass nginx
kubectl --context dev get clusterissuer letsencrypt-prod
kubectl --context dev -n ingress-nginx get svc ingress-nginx-controller-admission
```

Then enable Argo CD's configured Ingress and TLS host:

```bash
helm upgrade argocd argo/argo-cd --version 10.10.5 --namespace argocd --wait --kube-context dev --values helm/argocd/values.yaml
```

This ordering ensures cert-manager's HTTP-01 solver can create its temporary
Ingress after the `nginx` class and ingress-nginx admission Service exist. If
an older certificate Order is still pending after a failed presentation,
delete that Order to make cert-manager create a fresh one; do not delete the
Certificate or TLS Secret manually.

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
Prometheus, and Alertmanager are restricted by the trusted source CIDRs
configured in their values files. Keep those CIDRs current. OTEL ingestion
stays cluster-internal because the collector is an API endpoint rather than a
web UI.

The kube-prometheus-stack chart includes Kubernetes-mixin recording rules,
alert rules, and Grafana dashboards. The dev values explicitly keep those
enabled and allow Grafana's dashboard sidecar to discover dashboard ConfigMaps.
In Grafana, open **Dashboards** and look for the Kubernetes dashboards. In
Prometheus, check **Status → Targets** and **Alerts**. An empty firing-alert
list can be normal when no alert condition is active; configured rule groups
are visible separately in Prometheus under **Alerts**. To inspect what Argo
CD installed:

```bash
kubectl --context dev -n monitoring get prometheusrules
kubectl --context dev -n monitoring get configmaps -l grafana_dashboard=1
```

If these resources exist but Grafana has no Kubernetes dashboards, check the
Grafana dashboard sidecar logs and confirm the Prometheus data source is
healthy. If Prometheus dashboards show no data, check **Status → Targets** for
scrape failures before importing more dashboards; adding a second copy of the
Kubernetes mixin can create duplicate rules and dashboards.

This is a dev-grade, single-cluster setup, not a production-ready platform.
The admin tools are protected by source-IP allowlists, not SSO. Tempo is accessed from
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

## Pause and resume dev without destroying the cluster

Use this runbook for an overnight pause when the EKS control plane and data
should remain, but worker compute should stop. The managed node group and
Karpenter are independent capacity providers. Setting the managed node group
to zero alone is not enough: Karpenter can launch replacement nodes for
unscheduled system pods. Argo CD also self-heals live edits, so make the
Karpenter pause in Git and push it before scaling down compute.

### Pause dev

For the normal overnight pause, use the helper from Git Bash at the repository
root:

```bash
export AWS_PROFILE=sandbox3
bash scripts/pause-dev.sh
```

It asks for confirmation, changes the dev workload replicas and both
Karpenter NodePool CPU limits to zero, then adds, commits, and pushes only
those GitOps files to `develop`. It waits for Argo CD, drains Karpenter
NodeClaims, and sets the managed node group's minimum and desired size to zero
through the EKS API. It also changes the ignored local
`terraform/environments/dev/terraform.tfvars` `node_min_size` to zero, so a
later local Terraform plan will not restore the minimum while paused. The
script stops before scaling the managed group if apps have not scaled down or
Karpenter nodes have not drained. Keep the generated pause-state file in your
user profile; the resume script uses it to restore the original nodegroup
settings and find the exact pause commit.

The tracked pause values and Karpenter caps are committed and pushed by the
script. Resolve and push any changes to those same files first; the script
checks this to avoid mixing unrelated work into the pause commit.

1. Set the dev application and monitoring workload replicas to zero in their
   GitOps values/manifests. In the same change, set
   `spec.limits.cpu: "0"` in both
   `platform/karpenter/dev/nodepool-on-demand.yaml` and
   `platform/karpenter/dev/nodepool-spot.yaml`. Commit and push to `develop`.
   Do not rely on a live-only `kubectl patch`; Argo CD self-heal restores the
   values from Git.
2. Wait for Argo CD to apply the change. Check workload apps are synced and the
   NodePools have a zero CPU limit:

   ```bash
   kubectl --context dev -n argocd get applications -o wide
   kubectl --context dev -n argocd get application karpenter-config \
     -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
   kubectl --context dev get nodepools \
     -o custom-columns='NAME:.metadata.name,CPU-LIMIT:.spec.limits.cpu'
   ```

   Confirm `karpenter-config` is `Synced` and both NodePool CPU limits are `0`
   before continuing. This prevents Karpenter from replacing nodes while the
   managed node group drains. Also inspect disruption budgets before draining:

   ```bash
   kubectl --context dev get pdb -A
   ```

   A PDB with `ALLOWED DISRUPTIONS` equal to `0` can hold a drain while its
   required replicas are unavailable. Karpenter honors PDBs and, without a
   NodeClaim termination grace period, can wait indefinitely. For a predictable
   full pause, either configure an appropriate
   `spec.template.spec.terminationGracePeriod` on the NodePools before their
   NodeClaims are created, or include temporary PDB relaxation in the pause
   Git change and sync it before draining. A NodePool change does not update
   existing NodeClaims, so do not wait until shutdown night to add the grace
   period.
3. Review and apply the Terraform plan from
   `terraform/environments/dev`. The pause configuration sets the node group
   minimum to zero. Terraform's EKS module ignores the managed node group's
   `desired_size`, so a successful Terraform apply does not guarantee that
   desired capacity is zero.
4. Set the managed node group's actual desired capacity to zero:

   ```bash
   aws --profile sandbox3 eks update-nodegroup-config \
     --cluster-name eks-platform-demo-dev \
     --nodegroup-name nodegroup-worker-core-2e1b6f3add7fef027c250305c2 \
     --region eu-central-1 \
     --scaling-config minSize=0,maxSize=2,desiredSize=0
   ```

   Check the returned update ID with `aws eks describe-update`, and confirm
   `describe-nodegroup` reports `minSize: 0` and `desiredSize: 0`. A node shown
   as `Ready,SchedulingDisabled` may still be draining; wait until the ASG has
   no instances and the node disappears from Kubernetes.
5. After the managed node group is drained, the NodePool CPU limits remain
   zero, and PDBs allow the planned disruption (or the NodeClaims have a
   configured termination grace period), remove Karpenter-created nodes
   through their NodeClaims:

   ```bash
   kubectl --context dev get nodeclaims -o wide
   kubectl --context dev delete nodeclaims --all
   kubectl --context dev get nodes -o wide
   kubectl --context dev get nodeclaims -o wide
   ```

   Wait for the node and NodeClaim lists to become empty. Do not delete EC2
   instances directly while Karpenter is managing them. With no workers,
   Argo CD and other in-cluster controllers will be unavailable until compute
   is restored; the EKS control plane remains.

### Resume dev

To resume with the matching saved state, run:

```bash
export AWS_PROFILE=sandbox3
bash scripts/resume-dev.sh
```

The script restores the managed node group first and waits for its nodes and
Argo CD controllers to become Ready. It then reverts and pushes the pause
commit, which restores the saved workload replicas and Karpenter limits. The
local Terraform minimum is restored to its pre-pause value. If the pause
script did not complete, review its message before running resume.

1. Restore the managed node group to two nodes using the AWS CLI, while the
   Karpenter NodePools are still capped:

   ```bash
   aws --profile sandbox3 eks update-nodegroup-config \
     --cluster-name eks-platform-demo-dev \
     --nodegroup-name nodegroup-worker-core-2e1b6f3add7fef027c250305c2 \
     --region eu-central-1 \
     --scaling-config minSize=2,maxSize=2,desiredSize=2
   ```

2. Wait for the nodes to become `Ready`. Then revert the pause commit(s) in
   Git and push to `develop` to restore workload replicas and Karpenter
   NodePool limits. Review and apply the Terraform plan that restores the
   managed node group minimum to two. Argo CD will resume syncing once its
   pods are running.
3. Verify Argo CD applications are synced/healthy and check that no unexpected
   Karpenter NodeClaims remain:

   ```bash
   kubectl --context dev -n argocd get applications -o wide
   kubectl --context dev get nodes,nodeclaims -o wide
   ```

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

## CI pipelines and image publishing

The repository has a GitHub Actions workflow at
`.github/workflows/ci.yml` and an optional GitLab pipeline at
`.gitlab-ci.yml`.

Both pipelines scan for secrets, lint and render app Helm charts, run Python
and Java checks, build app images, and scan for critical vulnerabilities.
Terraform plans and add-on Helm charts are not tested by these pipelines.

To publish with GitHub, run the `applications-ci-and-publish` workflow
manually from `develop`, choose one app and `dev` or `qa`, then review and
merge the promotion PR. Configure `AWS_ROLE_ARN_DEV` and `AWS_ROLE_ARN_QA` as
GitHub repository variables. The workflow uses GitHub OIDC, not long-lived
AWS access keys. Allow the repository Actions token to create pull requests.

To publish with GitLab, configure GitLab OIDC and the project variables first,
then start a pipeline on `develop` with `APP_NAME` and `TARGET_ENV` set and
trigger the manual publish job. Follow the opt-in steps and least-privilege
token requirements in [.gitlab/README.md](../.gitlab/README.md). The GitLab
trust is disabled in Terraform by default and has no effect until enabled and
applied. Both CI systems create a merge request changing only the selected
environment's app image values; Argo CD deploys after that merge.

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
alias gpo='git push origin'
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
- GitLab CI pipeline and jobs: `.gitlab-ci.yml` and `.gitlab/ci/`
- Local port forwards: `scripts/port-forward.sh`
