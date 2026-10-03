# EKS platform demo

This test setup creates one Amazon EKS cluster for dev and deploys Python, Java, and NGINX sample apps. Terraform creates the VPC, EKS cluster, ECR repositories, and AWS roles. Argo CD deploys the apps and platform add-ons.

## No domain or HTTPS needed

There is no custom domain, Ingress, or public app endpoint in this setup. Services stay inside the cluster. For local testing, use `kubectl port-forward` to reach Argo CD, Grafana, or an app. The EKS Kubernetes API is public but restricted to the trusted `/32` IP addresses in the Terraform variables.

## Dev setup — run in this order

Use Git Bash from the repository directory. Before applying, confirm that the existing S3 bucket `tf-gitops-nikhil` exists in `eu-central-1` and that your AWS identity can access it. This bucket stores Terraform state and Velero backups; dev backups use the `backup/dev` prefix.

1. **Sign in to the intended AWS account.** These commands assume the AWS CLI profile is named `sandbox3`; replace it if yours differs.

   ```bash
   aws sso login --profile sandbox3
   aws sts get-caller-identity --profile sandbox3
   export AWS_PROFILE=sandbox3
   aws s3api head-bucket --bucket tf-gitops-nikhil
   ```

   Check that the returned account is the one where you intend to create the cluster.

2. **Prepare dev settings.** If `terraform/environments/dev/terraform.tfvars` does not exist, copy `terraform/environments/dev/terraform.tfvars.example` to that name. If it already exists, edit it instead of overwriting it. Set `cluster_endpoint_public_access_cidrs` to your current trusted public IP address or addresses, each ending in `/32`. Keep `create_github_oidc_provider = true` and `github_oidc_provider_arn = null`: dev will create the account-wide GitHub OIDC provider. Review the VPC CIDRs and node sizes if needed. Do not commit `terraform.tfvars`.

3. **Initialize and review Terraform.** In Git Bash:

   ```bash
   cd terraform/environments/dev
   terraform init
   terraform plan -out=tfplan
   terraform show tfplan
   ```

   Confirm the plan is for the expected AWS account and region, creates the dev EKS/ECR resources, and does not delete or replace anything unexpectedly. Then apply the reviewed plan:

   ```bash
   terraform apply tfplan
   ```

   AWS resources incur cost. Do not continue if the plan shows an unexpected destroy or replacement.

4. **Set up GitHub image publishing.** Get the dev role ARN:

   ```bash
   terraform output -raw github_actions_ecr_role_arn
   ```

   Add that value as the GitHub Actions repository variable `AWS_ROLE_ARN_DEV`. The workflow uses GitHub OIDC, so do not add AWS access keys. The same apply creates three dev ECR repositories: `eks-platform-demo/dev/python-demo`, `eks-platform-demo/dev/java-demo`, and `eks-platform-demo/dev/nginx-demo`.

5. **Publish the app images before syncing workloads.** In GitHub Actions, run the applications workflow from branch `develop` once for each app, selecting target `dev`. It builds and pushes an immutable image to that app's dev ECR repository, then opens a PR to update its Helm values. Review and merge each PR. The files under `helm/apps/<app>/values.yaml` intentionally start with image placeholders; the workflow replaces them. Do not sync the app Applications until these PRs have been merged. Allow the repository's GitHub Actions token to create PRs.

6. **Connect to the cluster and install Argo CD.** Terraform names the cluster `eks-platform-demo-dev` in `ap-south-1`. Still in Git Bash:

   ```bash
   aws eks update-kubeconfig --region ap-south-1 --name eks-platform-demo-dev --alias dev
   kubectl config use-context dev
   helm repo add argo https://argoproj.github.io/argo-helm --force-update
   helm repo update
   helm upgrade --install argocd argo/argo-cd --version 10.9.2 --namespace argocd --create-namespace --wait --kube-context dev
   kubectl --context dev apply -f ../../../platform/argocd/dev-root.yaml
   ```

   Run the last command from `terraform/environments/dev`, as in this sequence. The repository changes must be pushed to the GitHub repo and `develop` branch referenced by the Argo CD manifests. If Argo CD is already installed in this cluster, skip the Helm install.

7. **Optional: test External Secrets.** Create an AWS Secrets Manager secret named `eks-platform-demo/dev/demo-app` with JSON fields `username` and `password`. Do not put actual secret values in Git.

Use port-forwarding for local UI/app access. No DNS, TLS certificate, domain, or public load balancer is required. For example, Argo CD can be accessed locally by forwarding its service port; Grafana and app Services can be forwarded the same way.

## Where images come from

- **Python, Java, and NGINX apps:** Terraform creates one ECR repository per app per environment. GitHub Actions builds and pushes these images when you manually run the promotion workflow. It updates the app's Helm values through a PR.
- **Velero, Prometheus/Grafana, Tempo, OpenTelemetry, and other add-ons:** these are Helm charts, not app images built by this repository. Their charts select the images and versions (the chart versions are pinned in the Argo CD Applications); Velero's AWS plugin image is explicitly configured. Nodes need outbound access to the charts' public Helm repositories and container registries. These add-on images are not copied into this project's ECR by Terraform.

For exact Git Bash steps to push a local app image to ECR, optionally mirror add-on images, and deploy all add-ons, see [values2change.txt](eks-platform-demo/values2change.txt). Applying the matching Argo CD root deploys the add-ons; individual Helm installs are not needed.

## QA later

QA has its own Terraform state, cluster, ECR repositories, app image publishing role, Argo CD instance, and `backup/qa` Velero prefix. Dev creates the account-wide GitHub OIDC provider first; QA must reuse it. Copy the dev output `terraform output -raw github_oidc_provider_arn` into QA's `github_oidc_provider_arn` and set `create_github_oidc_provider = false` in QA's local tfvars. Set the GitHub Actions variable `AWS_ROLE_ARN_QA` from QA's `github_actions_ecr_role_arn` output. Apply QA from `terraform/environments/qa`, publish its app images to the `qa` target, then install a separate Argo CD instance in the QA cluster and apply `platform/argocd/qa-root.yaml` there. The bootstrap files are named consistently: `dev-root.yaml` and `qa-root.yaml`.

Secrets are organized by environment under `platform/secrets/dev/` and `platform/secrets/qa/`. Keep future environments (such as prod) in their own matching subdirectory.

## Useful locations

- Terraform roots: `terraform/environments/dev/` and `terraform/environments/qa/`
- AWS ECR Terraform module: `terraform/modules/ecr/`
- App charts and image values: `helm/apps/`
- Argo CD roots: `platform/argocd/`
- Cluster add-ons and values: `platform/addons/<environment>/`
- External Secrets manifests: `platform/secrets/<environment>/`