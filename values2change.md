EKS PLATFORM DEMO — DEV: FROM TERRAFORM APPLY TO RUNNING APPS
=============================================================

Recommended path after `terraform apply`: use GitHub Actions to build and push
app images, so Docker Desktop is not required on your PC. Then bootstrap Argo CD
once; the Argo root deploys all configured add-ons and app charts.

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

METHOD 1 (RECOMMENDED): GITHUB ACTIONS — LOCAL DOCKER NOT NEEDED

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

METHOD 2: BUILD/PUSH FROM THIS PC — DOCKER DESKTOP MUST BE RUNNING

If `docker` is installed but `docker info` reports that it cannot connect, the
Docker CLI is present but its engine is not running. Start Docker Desktop from
the Windows Start menu, wait until it reports that Docker is running, then run
`docker info` again. Terraform and Helm do not start Docker for you.

If your shell is still in terraform/environments/dev, return to the root first:

  cd ../../..

Run these commands from the repository root in Git Bash. The example builds
Python; change APP to java-demo or nginx-demo and use a new TAG for each push.
Your active AWS identity also needs ECR push permissions in this account.

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

To push an image you already downloaded instead of building this repo's app:

     docker pull SOURCE_REGISTRY/IMAGE:SOURCE_TAG
     docker tag SOURCE_REGISTRY/IMAGE:SOURCE_TAG "$IMAGE"
     docker push "$IMAGE"

After a manual push, edit helm/apps/<app>/values-dev.yaml in your branch:
  image.repository = <account>.dkr.ecr.eu-central-1.amazonaws.com/eks-platform-demo/dev/<app>
  image.tag        = <the TAG you pushed>
Do not include the tag in image.repository. Commit and push this values change
on develop. An ECR push alone does not deploy the image; Argo reads the values
from Git. Do not also run GitHub promotion for the same immutable tag.

C. OPTIONAL: DOWNLOAD/MIRROR THE ADD-ON HELM CHARTS
---------------------------------------------------

The dev add-ons currently use their pinned public Helm chart sources and the
images selected by those charts. With node outbound internet, you do not need
to download or mirror charts/images to deploy the test setup.

The script is optional. It downloads the pinned chart packages to the ignored
local folder artifacts/helm-charts/; its `push` command uploads those CHART
packages to ECR as OCI Helm charts. The script does not need Docker Desktop,
does not push the chart's container images, and does not change Argo CD sources.
Run from the repository root:

     bash scripts/mirror-addon-charts.sh --help
     bash scripts/mirror-addon-charts.sh download

Inspect the downloaded archives. Only if you deliberately want chart packages
in ECR, and your AWS identity has permission to create/push ECR repositories:

     bash scripts/mirror-addon-charts.sh push

Do not run `push` just to install the platform. To make Argo CD consume ECR
charts later, update each platform/addons/<environment>/<addon>/application.yaml
to its printed OCI chart reference and configure Argo CD's ECR registry
credentials. That is a separate change. Mirroring chart packages is also
separate from mirroring container images; image mirroring requires pulling,
retagging and pushing every image used by the chart (including subcharts,
sidecars and init containers), then setting the chart-specific image overrides.

D. INSTALL ARGO CD AND DEPLOY ALL DEV ADD-ONS/APPS
--------------------------------------------------

First commit/push all repository changes to the GitHub repository and branch
named in platform/argocd/dev-root.yaml and the child Applications. Make sure
every app's values-dev.yaml has a real image repository/tag (Method 1's PRs
must be merged, or Method 2's values edits committed).

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
