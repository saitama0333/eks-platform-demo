# EKS platform demo

This repository deploys Python, Java, and NGINX demo applications to separate
dev and QA EKS clusters. Terraform creates the clusters and ECR repositories.
Argo CD reads the configuration from the `develop` branch and deploys the
applications and platform add-ons.

There is no custom domain, Ingress, or public HTTPS endpoint. Services are
internal to the cluster; use `kubectl port-forward` for local testing.

## First-time provisioning

If the target EKS cluster or its ECR repositories do not exist yet, provision
them first from `terraform/environments/dev/` or
`terraform/environments/qa/`. Create the local `terraform.tfvars` from that
environment's example and set the trusted public IP CIDR(s). Then, from the
repository root in Git Bash, create and review a plan before applying it:

```bash
cd terraform/environments/dev # use qa for the QA environment
terraform init
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
cd ../../..
```

The Terraform state bucket must already exist. Never apply a plan that
contains unexpected changes. Keep `terraform.tfvars` local; do not commit it.

Dev creates the account-wide GitHub OIDC provider. QA should reuse the
`github_oidc_provider_arn` output from dev and set
`create_github_oidc_provider = false`.

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
