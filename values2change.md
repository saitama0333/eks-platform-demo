EKS PLATFORM DEMO — DEV: FROM TERRAFORM APPLY TO RUNNING APPS
=============================================================

If your personal laptop can reach the public image registries, build and push
the demo app images locally with `apps/image.sh`. If an office network blocks
Docker Hub, use the GitHub Actions workflow instead. Then bootstrap Argo CD
once; the Argo root deploys all configured add-ons and apps.

This test setup has no custom domain, Ingress, or public HTTPS endpoint. Apps
and add-on services are internal. The EKS API is public but restricted to the
trusted /32 CIDRs in terraform.tfvars.

A. RE-CREATE DEV AFTER DESTROY
------------------------------

1. Open Git Bash at the repository root and authenticate to the intended AWS
   account. Confirm the account printed is the one where the cluster belongs.
   The state bucket must already exist and be accessible.

     aws sso login --profile sandbox3
     aws sts get-caller-identity --profile sandbox3
     export AWS_PROFILE=sandbox3
     aws s3api head-bucket --bucket tf-gitops-nikhil

2. Check terraform/environments/dev/terraform.tfvars before proceeding:
   - Region is Frankfurt, eu-central-1; AZs must be available in that region.
   - cluster_endpoint_public_access_cidrs contains your current public IP(s)
     in /32 form.
   - create_github_oidc_provider = true and github_oidc_provider_arn = null.
   - Keep the existing VPC and Velero inputs unless you intend to change them.
   This local tfvars file is ignored by Git; do not commit it.

3. A previous terraform destroy may leave a stale local plan file. From Git
   Bash, run these commands to create a NEW plan and inspect it before applying:

     cd terraform/environments/dev
     rm -f tfplan
     terraform init
     terraform plan -out=tfplan
     terraform show tfplan

   Check that the plan creates the intended dev resources in eu-central-1 and
   has no unexpected destroy/replacement actions. Then apply that reviewed plan:

     terraform apply tfplan

   Terraform destroy deletes the resources it managed (and may fail if an ECR
   repository still has images), but it does not delete the separately managed
   Terraform state bucket. Re-apply creates the cluster, three app ECR repos,
   the GitHub OIDC provider, and the GitHub Actions push role again.

   While still in terraform/environments/dev, capture the role ARN, then return
   to the repository root:

     terraform output -raw github_actions_ecr_role_arn
     cd ../../..

B. PUT APP IMAGES IN ECR
------------------------

Terraform creates these repositories in Frankfurt:
  eks-platform-demo/dev/python-demo
  eks-platform-demo/dev/java-demo
  eks-platform-demo/dev/nginx-demo

Choose ONE image-publishing method for each app. Do not reuse a previously
pushed tag: ECR tags in these repositories are immutable.

METHOD 1: GITHUB ACTIONS — USE WHEN LOCAL REGISTRY ACCESS IS BLOCKED

1. If you did not capture the output at the end of section A, get it now:

    cd terraform/environments/dev
     terraform output -raw github_actions_ecr_role_arn
    cd ../../..

2. In GitHub, open the repository's Settings > Secrets and variables > Actions
   > Variables. Add or update repository variable AWS_ROLE_ARN_DEV with that
   full role ARN. It is a variable, not a secret. This role only works with the
   GitHub Actions OIDC trust configured in Terraform; do not add AWS access
   keys.

3. Push the current repository changes to the GitHub branch referenced by the
   Argo Applications (currently develop). In GitHub Actions, run the
   applications workflow from develop once per app, with target environment
   dev. It tests/builds/scans the app, pushes a commit-tagged image to ECR, and
   opens a PR updating that app's helm/apps/<app>/values-dev.yaml. Review and
   merge each PR. Argo CD deploys the value from Git after it is merged.

4. From the repository root, check that dev app values have no placeholders:

     grep -R -n 'REPLACE_WITH' helm/apps/*/values-dev.yaml

   If the command prints a dev values file, do not sync the dev root yet; merge
   the matching image promotion PR first.

METHOD 2: BUILD/PUSH FROM THIS PC — REQUIRES REGISTRY ACCESS

This method requires Docker Desktop to be running and the laptop to reach every
public base-image registry used by the Dockerfiles. A timeout to
`registry-1.docker.io` means the build cannot fetch its base image; logging in
to ECR does not fix access to Docker Hub. For a restricted office laptop, use
Method 1 (GitHub Actions) instead. The workflow builds on a GitHub-hosted
runner, pushes to ECR using GitHub OIDC, and opens a values-update PR.

If your shell is still in terraform/environments/dev, return to the root first:

  cd ../../..

Run these commands from the repository root in Git Bash only if Docker can pull
the public base images. The example builds Python; change APP to java-demo or
nginx-demo and use a new TAG for each push. Your active AWS identity also needs
ECR push permissions in this account. The convenience script `apps/image.sh`
builds and pushes all three apps, uses a unique tag, and prints their ECR URIs.
From the repo root, run:

  cd apps
  bash image.sh

     REGION=eu-central-1
     APP=python-demo
     TAG="$(date -u +%Y%m%d%H%M%S)"
     ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
     REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
     REPOSITORY="eks-platform-demo/dev/${APP}"
     IMAGE="${REGISTRY}/${REPOSITORY}:${TAG}"

     docker info
     aws ecr get-login-password --region "$REGION" |
       docker login --username AWS --password-stdin "$REGISTRY"
     docker build -f "apps/$APP/Dockerfile" -t "$IMAGE" "apps/$APP"
     docker push "$IMAGE"

To push a Docker image archive that you actually have as a Docker image, first
load it with `docker load -i <image-file.tar>`, then tag and push it. A Helm
chart archive under `artifacts/helm-charts/` is not a Docker image and cannot
be used this way. To push an already loaded source image instead of building
this repo's app:

     docker pull SOURCE_REGISTRY/IMAGE:SOURCE_TAG
     docker tag SOURCE_REGISTRY/IMAGE:SOURCE_TAG "$IMAGE"
     docker push "$IMAGE"

After a manual push, edit helm/apps/<app>/values-dev.yaml in your branch:
  image.repository = <account>.dkr.ecr.eu-central-1.amazonaws.com/eks-platform-demo/dev/<app>
  image.tag        = <the TAG you pushed>
Do not include the tag in image.repository. Commit and push this values change
on develop. An ECR push alone does not deploy the image; Argo reads the values
from Git. Do not also run GitHub promotion for the same immutable tag.

C. CHARTS NOW, PRIVATE ECR TARGET
---------------------------------------------------

The pinned chart archives are stored under `artifacts/helm-charts/` and
extracted into `artifacts/helm-charts/vendor/<chart-name>/`. Both the `.tgz`
archives and extracted chart directories are tracked in Git. Every dev and QA
chart Application points to that Git path, so Argo CD does not need public Helm
chart repositories. EKS nodes may still need outbound access to public
container image registries used by the charts.

This Git-vendored source is the current working setup. The production target is
to publish chart packages to private ECR OCI repositories and mirror every
rendered addon image to ECR. That target is **not active yet**: the Application
manifests still use Git paths, and there is not yet an addon image-mirror job,
image override set, or renewable Argo CD ECR credential configuration.

To change addon configuration, edit the Helm values file referenced by that
addon Application's `valueFiles`. These paths are for dev; QA has the matching
files under `platform/addons/qa/`.

| Addon | Chart | Values file |
| --- | --- | --- |
| AWS Load Balancer Controller | `aws-load-balancer-controller` | `platform/addons/dev/aws-load-balancer-controller/values.yaml` |
| External Secrets | `external-secrets` | `platform/addons/dev/external-secrets/values.yaml` |
| Karpenter | `karpenter` | `platform/addons/dev/karpenter/values.yaml` |
| Metrics Server | `metrics-server` | `platform/addons/dev/metrics-server/values.yaml` |
| OpenTelemetry Collector | `opentelemetry-collector` | `platform/addons/dev/opentelemetry-collector/values.yaml` |
| Prometheus, Alertmanager, and Grafana | `kube-prometheus-stack` | `platform/addons/dev/prometheus/values.yaml` |
| Tempo | `tempo` | `platform/addons/dev/tempo/values.yaml` |
| Velero | `velero` | `platform/addons/dev/velero/values.yaml` |

Grafana is enabled by the `kube-prometheus-stack` chart and configured in the
Prometheus values file; there is no separate Grafana Application here. The
chart and values wiring lives in each matching `application.yaml`. For example,
`platform/addons/dev/prometheus/application.yaml` pins the chart version and
references `platform/addons/dev/prometheus/values.yaml`.

`storage-gp3` is not a chart. Its Argo Application applies
`platform/storage/gp3-encrypted.yaml`, which creates the encrypted,
non-default `gp3-encrypted` EBS StorageClass. A workload must request a PVC
using this class to provision a volume.

The script downloads pinned chart packages and extracts them into the vendored
source directory. When all pinned archives already exist locally, `download`
works without contacting public chart repositories. Run from the repository
root:

     bash scripts/mirror-addon-charts.sh --help
     bash scripts/mirror-addon-charts.sh download

Commit the `.tgz` archives, extracted `artifacts/helm-charts/vendor/` chart
directories, and Application changes so Argo CD can read them from Git. The
script's `push` command publishes chart packages to
`ACCOUNT.dkr.ecr.eu-central-1.amazonaws.com/eks-platform-demo/addon-charts/<chart>`;
it does not push chart container images or switch Application sources.

If you deliberately want to publish chart packages to ECR as a separate
distribution mechanism, your AWS identity needs permission to create/push ECR
repositories:

     bash scripts/mirror-addon-charts.sh push

For the ECR chart migration, first create repositories with immutable tags,
encryption, scanning, and retention policies. Publish the pinned archives with
the script above. Then change each chart Application's chart source to its ECR
OCI repository while retaining the Git values source. An Argo OCI source uses
the registry hostname/path without the `oci://` prefix, plus the chart name and
version. Configure renewable ECR authentication for Argo CD before switching;
ECR login passwords expire, so a one-time local `helm registry login` is not
enough. Do not remove the Git-vendored source until the ECR-based Application
has synced successfully.

The currently rendered addon image references to mirror are:

  public.ecr.aws/eks/aws-load-balancer-controller:v2.14.0
  oci.external-secrets.io/external-secrets/external-secrets:v0.15.1
  public.ecr.aws/karpenter/controller:1.6.2@sha256:1378b7c2fdf1c63e7d7c91db93c68309efd6d4c0bc24ab946968bf858a88e24e
  registry.k8s.io/metrics-server/metrics-server:v0.7.2
  otel/opentelemetry-collector-contrib:0.117.0
  docker.io/bitnami/kubectl:1.37
  grafana/grafana:13.2.2-distroless
  ghcr.io/jkroepke/kube-webhook-certgen:1.8.8
  quay.io/kiwigrid/k8s-sidecar:2.11.2
  quay.io/prometheus/alertmanager:v0.34.1
  quay.io/prometheus/node-exporter:v1.12.1-distroless
  quay.io/prometheus/prometheus:v3.14.0-distroless
  quay.io/prometheus-operator/prometheus-operator:v0.94.1
  registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0
  grafana/tempo:2.8.0
  velero/velero:v1.15.2
  velero/velero-plugin-for-aws:v1.10.0

This inventory was rendered from the current dev/QA charts and values. Re-run
the image inventory after changing any chart version or enabling chart
features; optional exporters and sidecars can add images. Mirror multi-platform
images without dropping architectures, scan them, record source/destination
digests, and set every chart-specific image override in both environments.
The ECR Terraform module currently creates only the three app repositories, not
these addon chart/image repositories.

D. INSTALL ARGO CD AND DEPLOY ALL DEV ADD-ONS/APPS
--------------------------------------------------

First commit/push all repository changes to the GitHub repository and branch
named in platform/argocd/dev-root.yaml and the child Applications. Make sure
every app's values-dev.yaml has a real image repository/tag (Method 1's PRs
must be merged, or Method 2's values edits committed).

Also commit the extracted chart directories under
`artifacts/helm-charts/vendor/`. Argo CD reads these paths from the Git branch;
files that exist only on your laptop are not available to the cluster.

From the repository root in Git Bash, connect to the Frankfurt dev cluster,
install Argo CD once, then apply its root Application:

     aws eks update-kubeconfig --region eu-central-1 \
       --name eks-platform-demo-dev --alias dev
     kubectl config use-context dev
     helm repo add argo https://argoproj.github.io/argo-helm --force-update
     helm repo update
     helm upgrade --install argocd argo/argo-cd --version 10.9.2 \
       --namespace argocd --create-namespace --wait --kube-context dev
     kubectl --context dev apply -f platform/argocd/dev-root.yaml

The root creates all dev Application objects under platform/addons/dev/ and
platform/apps/dev/. Argo CD fetches each pinned add-on chart and installs it;
you do NOT separately run `helm install` for every add-on. The root also
installs the sample apps, so their image values must be ready first. If Argo CD
is already installed in this cluster, skip the Helm upgrade command.

Watch deployment:

     kubectl --context dev -n argocd get applications
     kubectl --context dev get pods -A

Use `kubectl port-forward` for local access to services; no domain or public
HTTPS endpoint is part of this setup. Do not install a release manually with
Helm if Argo CD already manages that same release.

E. OPTIONAL: AWS SECRETS MANAGER TEST
-------------------------------------

Create AWS Secrets Manager secret eks-platform-demo/dev/demo-app with JSON
fields username and password. Never commit secret values. Dev External Secrets
manifests are under platform/secrets/dev/.

QA uses a separate cluster/context, ECR app repositories and app values files
values-qa.yaml. Dev creates the account-wide GitHub OIDC provider; QA must set
create_github_oidc_provider = false and reuse dev's github_oidc_provider_arn.
Apply only platform/argocd/qa-root.yaml to the QA context after QA is ready.
