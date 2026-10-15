# EKS platform demo

This repository deploys Python, Java, and NGINX demo applications to separate
dev and QA EKS clusters. Terraform creates the clusters and ECR repositories.
Argo CD reads the configuration from the `develop` branch and deploys the
applications and platform add-ons.

There is no custom domain, Ingress, or public HTTPS endpoint. Services are
internal to the cluster; use `kubectl port-forward` for local testing.

## Start from zero: dev

Use this sequence if dev was destroyed and you want to rebuild it. Run the
commands from Git Bash at the repository root, and replace `sandbox3` with
your AWS CLI profile. Confirm the AWS account is the intended account before
creating or deleting resources:

```bash
aws sso login --profile sandbox3
export AWS_PROFILE=sandbox3
aws sts get-caller-identity
aws s3api head-bucket --bucket tf-gitops-nikhil --region eu-central-1
```

The existing S3 bucket is required for Terraform state and Velero backups.
The dev Terraform state uses the `dev/terraform.tfstate` key. Do not delete
the bucket or alter the state key as part of rebuilding dev.

If this is the first local checkout setup, create
`terraform/environments/dev/terraform.tfvars` from
`terraform/environments/dev/terraform.tfvars.example`. Set
`cluster_endpoint_public_access_cidrs` to your current trusted public IP
address in `/32` form. Keep the dev account OIDC settings as
`create_github_oidc_provider = true` and `github_oidc_provider_arn = null`.
Review network and node-size values. Keep this local file out of Git.

Provision the cluster, ECR repositories, IAM roles, and supporting AWS
resources:

```bash
cd terraform/environments/dev
terraform init
terraform plan -out=tfplan
terraform show tfplan
```

Review the plan for the expected AWS account, Frankfurt region
(`eu-central-1`), and dev resources. Do not apply an unexpected destroy or
replacement. Apply the reviewed plan:

```bash
terraform apply tfplan
terraform output sample_app_ecr_repositories
terraform output -raw github_actions_ecr_role_arn
terraform output -raw github_oidc_provider_arn
cd ../../..
```

Record the OIDC provider ARN securely for future QA provisioning. If using
GitHub Actions to publish images, set the GitHub repository variable
`AWS_ROLE_ARN_DEV` to the `github_actions_ecr_role_arn` output. Terraform
creates the dev ECR repositories, but does not publish application images.

Continue with [Deployment order](#deployment-order): build and push all three
images (or use GitHub Actions), commit/push the image values and any desired
platform-values changes to `develop`, install or upgrade Argo CD, and apply
`platform/argocd/dev-root.yaml`. Do not apply the root until the dev image
values contain real ECR repository names and tags.

### If dev was destroyed

`terraform destroy` removes the dev cluster and its Terraform-managed AWS
resources. It does not remove the separately managed Terraform/Velero S3
bucket or the objects in it. It will also remove dev's account-wide GitHub OIDC
provider if dev created it; any already-running QA GitHub Actions role that
uses that provider will stop working until the provider is recreated and QA
is updated to use its new ARN.

The ECR repositories are configured with `force_delete = false`. Terraform
cannot delete a repository that still contains images. If you want Terraform
to remove the repositories as part of destroy, first decide whether those
images are disposable, then delete them from the three dev repositories in
the ECR console. Deleting images is irreversible. Keep the S3 state bucket
and its state objects; do not manually delete or edit the remote state.

Before destroying, back up any app or monitoring data you need. The current
Velero schedule covers only the `default` namespace, and EBS volumes are not
backed up by this configuration (`snapshotsEnabled` is false). Destroying the
cluster can therefore remove PVC-backed app and monitoring data.

To preview and perform a full dev destroy, after confirming the AWS account and
that the ECR images and cluster data can be deleted:

```bash
cd terraform/environments/dev
terraform init
terraform plan -destroy -out=tfplan-destroy
terraform show tfplan-destroy
```

Only if the plan targets the intended dev resources and you accept the data
loss, run:

```bash
terraform apply tfplan-destroy
```

If destroy fails because ECR repositories contain images, read the error,
delete only the intended dev images, and re-create and review a new destroy
plan before applying it. Do not delete the QA repositories or shared S3 bucket.
After destroy succeeds, follow [Start from zero: dev](#start-from-zero-dev).

## Add QA later

Keep dev in place while creating QA. QA has its own Terraform state key,
cluster, ECR repositories, and Velero prefix, but reuses the account-wide
GitHub OIDC provider created by dev.

Copy `terraform/environments/qa/terraform.tfvars.example` to
`terraform/environments/qa/terraform.tfvars`. Set the trusted public API CIDR
and replace `REPLACE_WITH_DEV_GITHUB_OIDC_PROVIDER_ARN` with the value recorded
from dev's `terraform output -raw github_oidc_provider_arn`. Keep
`create_github_oidc_provider = false`.

Then run the reviewed Terraform plan and apply from the QA directory:

```bash
cd terraform/environments/qa
terraform init
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output sample_app_ecr_repositories
terraform output -raw github_actions_ecr_role_arn
cd ../../..
```

If using GitHub Actions, set the repository variable `AWS_ROLE_ARN_QA` to the
QA role ARN. Build and push QA images using `bash apps/image.sh qa`, then
review and push the `values-qa.yaml` updates to `develop`, or use the Actions
promotion workflow and merge its PRs. Finally connect to the QA cluster,
install Argo CD there if it is not already installed, and apply
`platform/argocd/qa-root.yaml` with the `qa` context. Use the same deployment,
verification, and UI-access steps below with `ENVIRONMENT=qa`.

If dev is destroyed after QA has been created, restore dev first, capture the
new `github_oidc_provider_arn`, update QA's local `terraform.tfvars`, then
review and apply a QA Terraform plan before relying on QA's GitHub Actions
image-publishing role again.

## Deployment order

1. **Make sure the target cluster and its ECR repositories exist.** Terraform
   creates them. Do not re-apply Terraform just to publish images or deploy
   applications. Dev and QA are separate clusters and use separate ECR paths.

2. **Build and publish the three app images.** From the repository root in
   Git Bash, sign in to the AWS account that owns the target ECR repositories.
   Docker Desktop must be running, and the laptop must be able to reach the
   public base-image registries used by the Dockerfiles:

   ```bash
   aws sso login --profile sandbox3
   export AWS_PROFILE=sandbox3
   aws sts get-caller-identity
   cd apps
   bash image.sh dev
   cd ..
   ```

   Replace `sandbox3` with your AWS CLI profile. The script builds and pushes
   all three apps with one new immutable tag, then updates the matching
   `helm/apps/<app>/values-dev.yaml` files with the ECR repository and tag.
   Review the changes with:

   ```bash
   git diff -- helm/apps
   ```

   For QA, run `bash image.sh qa` instead. The script updates each app's
   `values-qa.yaml`. For another environment, pass its name if that
   environment's ECR repositories and all three `values-<environment>.yaml`
   files have already been created. If local Docker cannot reach a base-image
   registry, use the GitHub Actions method below instead.

   Your AWS identity needs permission to push to the target ECR repositories.
   A timeout while pulling a public base image means local publishing is
   blocked; use the GitHub Actions method below instead. Do not reuse an
   existing tag because ECR tags are immutable.

3. **Commit and push the image values to `develop`.** The Argo CD Applications
   in this repository track that branch:

   ```bash
   git add helm/apps/*/values-dev.yaml platform/addons/dev
   git commit -m "Update application images"
   git push origin develop
   ```

   For QA, stage `helm/apps/*/values-qa.yaml platform/addons/qa` instead. If
   you built images for more than one environment, stage both sets after
   reviewing the diff.

4. **Connect to the target EKS cluster and install Argo CD if needed.** Run
   these commands from the repository root in Git Bash. Set the environment
   to `dev` or `qa`:

   ```bash
   ENVIRONMENT=dev
   aws eks update-kubeconfig --region eu-central-1 \
     --name "eks-platform-demo-${ENVIRONMENT}" --alias "$ENVIRONMENT"
   kubectl config use-context "$ENVIRONMENT"
   ```

   Check whether Argo CD is already running in that cluster:

   ```bash
   kubectl --context "$ENVIRONMENT" get pods -n argocd
   ```

   If Argo CD is not installed, bootstrap it once in that cluster:

   ```bash
   helm repo add argo https://argoproj.github.io/argo-helm --force-update
   helm repo update
   helm upgrade --install argocd argo/argo-cd --version 10.10.5 \
     --namespace argocd --create-namespace --wait \
     --kube-context "$ENVIRONMENT"
   ```

   This pins Argo CD Helm chart `10.10.5` (Argo CD application `v3.5.5`).
   This is the current upstream chart release checked on 15 October 2026;
   see the [upstream chart metadata](https://github.com/argoproj/argo-helm/blob/main/charts/argo-cd/Chart.yaml).
   Running the command again upgrades the existing Helm release; review the
   release notes and back up important configuration before upgrading an
   existing installation.

5. **Apply the environment root Application.** This is the only manual
   deployment step after bootstrapping Argo CD. The root discovers and applies
   that environment's app and add-on Applications. Argo CD then fetches the
   pinned public add-on charts and deploys the app charts using their committed
   values. Do not manually install Helm releases that Argo CD manages.

   ```bash
   kubectl --context "$ENVIRONMENT" apply \
     -f "platform/argocd/${ENVIRONMENT}-root.yaml"
   ```

   The matching image values must already be committed to `develop`.

6. **Check the rollout:**

   ```bash
   kubectl --context "$ENVIRONMENT" -n argocd get applications
   kubectl --context "$ENVIRONMENT" get pods -A
   ```

   App and add-on pods need outbound access to the image registries they use.

## Publish images with GitHub Actions instead

Use this method if the laptop cannot reach a public base-image registry. In
GitHub Actions, run the `applications-ci-and-publish` workflow from `develop`,
select the app and target environment, then review and merge the image
promotion PR. The workflow pushes the image and updates the matching app
values file. Merge the PR, then continue at step 4 above; you can skip the
local values commit in step 3.

The workflow uses GitHub OIDC, not AWS access keys. Configure the
`AWS_ROLE_ARN_DEV` and/or `AWS_ROLE_ARN_QA` repository variable using the
matching Terraform `github_actions_ecr_role_arn` output. Allow the repository
Actions token to create pull requests. Do not run local image publishing and
GitHub promotion for the same app/tag.

## If an Argo CD pod is deleted

Argo CD runs **inside the EKS cluster**. Port-forwarding only gives your
computer temporary access to its web service; it does not run Argo CD locally.
For example, this command forwards the Argo CD web service to your computer:

```bash
kubectl --context "$ENVIRONMENT" -n argocd \
  port-forward svc/argocd-server 8080:443
```

Open `https://localhost:8080` while the command is running.

If a pod is deleted or crashes, Kubernetes recreates it from its Deployment or
StatefulSet. A short interruption does not normally require reinstalling Argo
CD.

Argo CD's desired application configuration is kept in Git, while its live
Application resources, settings, and credentials are Kubernetes objects in
the `argocd` namespace (stored by the EKS cluster's Kubernetes control plane).
The default installation here does not configure a persistent volume for Argo
CD's Redis cache; that cache can be rebuilt. Application workloads and any
volumes they use are separate from Argo CD.

If the whole cluster is deleted, Argo CD's in-cluster objects are deleted too.
Recreate the cluster, install Argo CD again, and apply the matching root
manifest; the configuration committed to Git can be reconciled again.

## Argo CD components and GitOps flow

The Helm command above bootstraps Argo CD into the `argocd` namespace. It
creates the server, application controller, repository server, Redis cache,
Dex, ApplicationSet controller, and notifications components according to the
chart defaults. Dex is present, but no identity-provider connector is
configured here; this demo uses the local Argo CD admin account, not SSO.
Inspect the installed components with:

```bash
kubectl --context "$ENVIRONMENT" -n argocd get pods,deployments,statefulsets,services
```

The bootstrap Helm release is not itself managed by the root Application.
After bootstrapping, applying `platform/argocd/<environment>-root.yaml` creates
the root Application. It watches this repository's `develop` branch and
creates child Applications from `platform/addons/<environment>/` and
`platform/apps/<environment>/`. Those child Applications reconcile the
committed Helm values and manifests. The flow is:

`commit/push to develop -> root Application -> child Applications -> cluster`

The charts for add-ons are pinned in their `application.yaml` files. The
Argo CD Helm chart version is pinned in the bootstrap command above. Keep
credentials and SSO client secrets out of Git; use a secret manager for them.

### Upgrade an existing Argo CD installation

The current repository does not contain a `platform/dev-values.yaml` file.
Argo CD itself is installed by the Helm release; `platform/argocd/dev-root.yaml`
is the GitOps root Application, not Argo CD Helm values. The addon values live
under `platform/addons/dev/<addon>/values.yaml`.

Before upgrading, confirm that your AWS profile and kube context point to the
demo dev cluster, not another cluster. Check the existing Helm release name and
version. Keep a private backup of its user-supplied Helm values; do not commit
the backup because it may contain credentials:

```bash
aws sso login --profile sandbox3
export AWS_PROFILE=sandbox3
aws sts get-caller-identity
aws eks describe-cluster --region eu-central-1 \
  --name eks-platform-demo-dev --query 'cluster.arn' --output text
aws eks update-kubeconfig --region eu-central-1 \
  --name eks-platform-demo-dev --alias dev
CTX=dev
kubectl --context "$CTX" get nodes
helm list --kube-context "$CTX" --namespace argocd
helm get values argocd --kube-context "$CTX" --namespace argocd \
  --output yaml > "$HOME/argocd-values-backup.yaml"
```

Proceed only after confirming the cluster and release are correct. Review the
current Argo CD release notes if the installed version is several major
versions behind. Then upgrade the existing release while retaining its
previous user-supplied values:

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update
helm upgrade argocd argo/argo-cd --version 10.10.5 \
  --namespace argocd --reuse-values --wait --timeout 10m \
  --kube-context "$CTX"
helm list --kube-context "$CTX" --namespace argocd
kubectl --context "$CTX" get pods,deployments,statefulsets -n argocd
kubectl --context "$CTX" rollout status deployment/argocd-server --timeout=10m
kubectl --context "$CTX" rollout status statefulset/argocd-application-controller --timeout=10m
```

The pinned chart is `10.10.5` and packages Argo CD `v3.5.5`. `helm repo
update` only refreshes the local chart index; the `helm upgrade` command is
what changes the running Argo CD components. A chart upgrade updates its
server, controller, repo-server, Redis, Dex, ApplicationSet, and notifications
components according to the release values. It does not update the separate
charts managed by child Applications.

To apply the monitoring persistence and Collector scrape changes in this
repository, first commit and push the intended dev values to `develop`. Argo
CD should then sync the child Applications automatically. If the root is not
yet installed, or needs to be re-applied, run:

```bash
kubectl --context "$CTX" apply -f platform/argocd/dev-root.yaml
kubectl --context "$CTX" -n argocd get applications
```

Do not use `helm upgrade --install` with a guessed values file on an existing
release; it may replace important configuration. `--reuse-values` retains
the existing release overrides. It does not restore custom settings that
were never stored in the Helm release.

## Access the web UIs and workloads

Run each `port-forward` in its own Git Bash window and leave it running while
using that UI. These services are internal; port-forwarding does not create a
public endpoint.

| UI/service | Command | URL |
| --- | --- | --- |
| Argo CD | `kubectl --context "$ENVIRONMENT" -n argocd port-forward svc/argocd-server 8080:443` | `https://localhost:8080` |
| Grafana | `kubectl --context "$ENVIRONMENT" -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` | `http://localhost:3000` |
| Prometheus | `kubectl --context "$ENVIRONMENT" -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` | `http://localhost:9090` |
| Alertmanager | `kubectl --context "$ENVIRONMENT" -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093` | `http://localhost:9093` |
| Python app | `kubectl --context "$ENVIRONMENT" -n default port-forward svc/python-demo 8081:80` | `http://localhost:8081` |
| Java app | `kubectl --context "$ENVIRONMENT" -n default port-forward svc/java-demo 8082:80` | `http://localhost:8082` |
| NGINX app | `kubectl --context "$ENVIRONMENT" -n default port-forward svc/nginx-demo 8083:80` | `http://localhost:8083` |

Tempo and the OpenTelemetry Collector do not provide a user-facing dashboard.
Use Grafana Explore with the configured Tempo data source to view traces.
Collector logs are currently sent to its debug exporter, not a persistent log
store, so this setup does not provide searchable historical logs.

The Grafana username is `admin`. Read its generated password from the cluster:

```bash
kubectl --context "$ENVIRONMENT" -n monitoring get secret \
  kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
printf '\n'
```

For the initial Argo CD admin password, use:

```bash
kubectl --context "$ENVIRONMENT" -n argocd get secret \
  argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
printf '\n'
```

There is no cluster-wide Kubernetes dashboard installed. List pods in every
namespace with `kubectl --context "$ENVIRONMENT" get pods -A`; use
`kubectl logs`, `kubectl describe`, and `kubectl exec` for individual
workloads. A local Kubernetes client such as `kubectl`, Lens, or k9s can use
the same kubeconfig and AWS access, subject to the EKS endpoint CIDR and
Kubernetes permissions.

## Monitoring and data retention

For dev and QA, Prometheus retains metrics for up to seven days or 18 GB,
whichever limit is reached first, on a 20 GiB encrypted gp3 volume. Grafana,
Alertmanager, and Tempo each have their own encrypted gp3 persistent volume
(5 GiB, 5 GiB, and 10 GiB respectively). The `storage-gp3` Application creates
the `gp3-encrypted` StorageClass used by these claims. Provisioning these
volumes incurs AWS storage charges in each environment.

Persistent volumes survive pod restarts and replacements, but this is not a
backup or disaster-recovery setup. The volumes are AZ-bound EBS disks; deleting
their PVCs or cluster can delete the data. Velero is configured to back up
workloads in the `default` namespace, not monitoring or Argo CD, and the
current logs pipeline has no persistent backend. Add and test backups and
restores before treating any stored data as important.

## Diagnose an OutOfSync Application

`OutOfSync` means the live resources differ from the manifests Argo CD reads
from Git. It is not, by itself, enough to identify the cause. First make sure
the intended values and manifests have been committed and pushed to `develop`;
uncommitted local edits are invisible to Argo CD. Then check sync and health
status and read the Application's reported conditions:

```bash
kubectl --context "$ENVIRONMENT" -n argocd get applications
kubectl --context "$ENVIRONMENT" -n argocd describe application python-demo
kubectl --context "$ENVIRONMENT" -n default get pods,events --sort-by=.metadata.creationTimestamp
```

Replace `python-demo` with the affected Application. Check pod events for
image-pull errors, missing PVC/StorageClass, failed scheduling, or readiness
probe failures. Most child Applications have automated sync and self-heal
enabled; resolve the reported error and allow reconciliation before manually
syncing. Do not use Helm to change a release that Argo CD owns.

## Production-readiness boundary

This is a demonstration setup, not production-ready as-is. Argo CD and the
monitoring services use single replicas and the default standalone Redis
cache; SSO, alert receivers, a public authenticated HTTPS endpoint, and
monitoring-data backups are not configured. A production deployment needs a
reviewed SSO/RBAC design, private or authenticated HTTPS access, HA and
capacity planning, backup/restore tests for stateful data, alert routing,
controlled promotion and rollback, image and chart vulnerability/update
management, and tested disaster recovery. The public EKS API is restricted by
configured trusted IP CIDRs, but that alone does not make the platform
production-ready.

## Useful locations

- Argo CD roots: `platform/argocd/dev-root.yaml` and `platform/argocd/qa-root.yaml`
- Argo CD app definitions: `platform/apps/<environment>/`
- App charts and image values: `helm/apps/`
- Add-on charts, Applications, and values: `platform/addons/<environment>/`
- Terraform environments: `terraform/environments/dev/` and `terraform/environments/qa/`
- Local image publishing script: `apps/image.sh`


===
Test
Find files matching `eks-platform-demo/platform/**/*.yaml`

Read 
Completed with input: {
  "path": "c:\\Users\\A200159779\\Downloads\\Repo\\POC\\eks-platform-demo\\platform\\argocd\\dev-root.yaml"
}

Read 
Completed with input: {
  "path": "c:\\Users\\A200159779\\Downloads\\Repo\\POC\\eks-platform-demo\\scripts\\mirror-addon-charts.sh"
}

Search for `helm upgrade|helm install|argo/argo-cd|dev-values.yaml|dev-root.yaml|argocd`

Ran terminal command: Get-Command helm,kubectl -ErrorAction SilentlyContinue | Select-Object Name,Source; kubectl config get-contexts -o name

Edit 

Ran terminal command: git -C 'C:\Users\A200159779\Downloads\Repo\POC\eks-platform-demo' diff --check; if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}; git -C 'C:\Users\A200159779\Downloads\Repo\POC\eks-platform-demo' status --short

Read , lines 190 to 285
Completed with input: {
  "path": "c:\\Users\\A200159779\\Downloads\\Repo\\POC\\eks-platform-demo\\README.md",
  "view_range": [
    190,
    285
  ]
}

Get file or directory contents
Completed with input: {
  "owner": "argoproj",
  "repo": "argo-helm",
  "path": "charts/argo-cd/Chart.yaml",
  "ref": "refs/heads/main",
  "fields": [
    "name",
    "path",
    "sha"
  ]
}

Added artifact "Argo CD upgrade and GitOps instructions"
Completed with input: {
  "items": [
    {
      "type": "file",
      "label": "Argo CD upgrade and GitOps instructions",
      "isArtifact": true,
      "uri": "file:///c:/Users/A200159779/Downloads/Repo/POC/eks-platform-demo/README.md"
    }
  ]
}

Argo CD itself is installed by a **Helm release** named `argocd` in the cluster’s `argocd` namespace. That release provides the server, application controller, repo-server, Redis, Dex, ApplicationSet controller, and notifications. The chart defaults enable Dex, but this repo does not configure an SSO provider.

In this checkout there is **no `platform/dev-values.yaml`**. `platform/argocd/dev-root.yaml` is the GitOps root Application—not Helm values. Add-on values are under `platform/addons/dev/<addon>/values.yaml`.

I checked the upstream chart metadata: chart **10.10.5** packages Argo CD **v3.5.5**. The updated commands are also in `README.md`.

### Upgrade Argo CD in dev

My available kubeconfig had `careerportal-preprod` as its active context, so I **did not run commands against your cluster**. These commands explicitly configure the demo dev context and check it before changing anything. Run them from Git Bash at the repository root:

```bash
aws sso login --profile sandbox3
export AWS_PROFILE=sandbox3

aws sts get-caller-identity
aws eks describe-cluster --region eu-central-1 \
  --name eks-platform-demo-dev --query 'cluster.arn' --output text

aws eks update-kubeconfig --region eu-central-1 \
  --name eks-platform-demo-dev --alias dev

CTX=dev
kubectl --context "$CTX" get nodes
helm list --kube-context "$CTX" --namespace argocd
```

Confirm the AWS account, cluster, and Helm release are the intended ones. Back up the existing release values privately—**don’t commit or share this file**, as it may contain credentials:

```bash
helm get values argocd --kube-context "$CTX" --namespace argocd \
  --output yaml > "$HOME/argocd-values-backup.yaml"
```

If the installed Argo CD is several major versions behind, review the upstream upgrade notes before proceeding. Then upgrade the existing release and keep its Helm-stored overrides:

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

helm upgrade argocd argo/argo-cd --version 10.10.5 \
  --namespace argocd --reuse-values --wait --timeout 10m \
  --kube-context "$CTX"

helm list --kube-context "$CTX" --namespace argocd
kubectl --context "$CTX" get pods,deployments,statefulsets -n argocd
kubectl --context "$CTX" rollout status deployment/argocd-server --timeout=10m
kubectl --context "$CTX" rollout status statefulset/argocd-application-controller --timeout=10m
```

`helm repo update` only refreshes Helm’s local chart index; `helm upgrade` is what updates the running Argo CD components. `--reuse-values` retains overrides saved in the Helm release. It cannot recover settings that were never stored there.

### Apply the dev add-on changes

Argo CD does **not** automatically see local, unpushed edits. Commit and push the changed dev values to the branch the Applications track (`develop`):

```bash
git add platform/addons/dev/prometheus/values.yaml \
  platform/addons/dev/tempo/values.yaml \
  platform/addons/dev/opentelemetry-collector/values.yaml
git commit -m "Persist monitoring data and scrape OpenTelemetry"
git push origin develop
```

Existing child Applications should then reconcile those changes automatically. Check their status:

```bash
kubectl --context "$CTX" -n argocd get applications
```

Only if the root Application is missing or needs applying:

```bash
kubectl --context "$CTX" apply -f platform/argocd/dev-root.yaml
```

This updates Argo CD and applies the monitoring configuration in Git; it **does not upgrade every pinned add-on chart**. Those chart versions are separately pinned in each add-on’s `application.yaml`, and should be changed and tested individually rather than blindly moved to “latest.”