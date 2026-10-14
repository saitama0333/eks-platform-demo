The EKS cluster is already provisioned. Do not rerun Terraform just to publish images or deploy the apps.

## Build and push app images from your laptop

Use this path on a laptop where Docker can reach Docker Hub and the other public base-image registries. It builds all three apps, logs in to ECR, and pushes one unique tag per run. The ECR repositories must already exist from Terraform, and your AWS identity needs ECR push permission.

From the repository root in Git Bash:

```bash
aws sso login --profile sandbox3
export AWS_PROFILE=sandbox3
aws sts get-caller-identity
cd apps
bash image.sh
```

Replace `sandbox3` with your AWS CLI profile. Record the tag and ECR image URIs printed by the script. For each app, update `image.repository` and `image.tag` in `helm/apps/<app>/values-dev.yaml`; do not include the tag in the repository field. Commit and push those values changes to `develop`. Argo CD deploys after the changes reach Git.

If Docker reports a timeout pulling a base image, this laptop cannot perform the local build. Use **Actions > applications-ci-and-publish > Run workflow** on `develop`, select the app and `dev`, then review and merge its image-promotion PR. That route builds on a GitHub-hosted runner and pushes using OIDC. Set the GitHub repository variable `AWS_ROLE_ARN_DEV` from `terraform output -raw github_actions_ecr_role_arn` first.

## Deploy with Argo CD

Apply [dev-root.yaml](../platform/argocd/dev-root.yaml) once to the existing cluster after app image values are committed and pushed to `develop` (merge the promotion PRs if using GitHub Actions). It discovers the child Applications under `platform/addons/dev/` and `platform/apps/dev/`. Do not manually `helm install` a release that Argo CD manages. See [values2change.md](../values2change.md) for the complete cluster connection and Argo bootstrap commands.

## Addon chart values

Each child `application.yaml` selects a Helm chart/version and points to a values file in that addon directory. Edit the listed values file, commit it to `develop`, and let Argo CD sync it.

| Addon | Chart | Dev values file |
| --- | --- | --- |
| AWS Load Balancer Controller | `aws-load-balancer-controller` | `platform/addons/dev/aws-load-balancer-controller/values.yaml` |
| External Secrets | `external-secrets` | `platform/addons/dev/external-secrets/values.yaml` |
| Karpenter | `karpenter` | `platform/addons/dev/karpenter/values.yaml` |
| Metrics Server | `metrics-server` | `platform/addons/dev/metrics-server/values.yaml` |
| OpenTelemetry Collector | `opentelemetry-collector` | `platform/addons/dev/opentelemetry-collector/values.yaml` |
| Prometheus, Alertmanager, and Grafana | `kube-prometheus-stack` | `platform/addons/dev/prometheus/values.yaml` |
| Tempo | `tempo` | `platform/addons/dev/tempo/values.yaml` |
| Velero | `velero` | `platform/addons/dev/velero/values.yaml` |

Grafana is enabled inside `kube-prometheus-stack`; it is not a separate chart in this setup. For QA, use the matching `platform/addons/qa/<addon>/values.yaml` and QA Application. App image values are separate: `helm/apps/<app>/values-dev.yaml` and `helm/apps/<app>/values-qa.yaml`.

## Current chart and image sources

Today, Argo CD reads extracted chart sources from `artifacts/helm-charts/vendor/` in this Git repository. The pinned `.tgz` archives and extracted `vendor/` directories are tracked. Each addon Application's `path` points to a chart directory and `valueFiles` selects the environment values shown above. This avoids public Helm chart repositories, but it does not move the charts into ECR. Addon workloads still use their upstream image registries by default.

## Production ECR migration status

The intended production model is to publish the approved chart archives to ECR as OCI charts and mirror every chart image into private ECR repositories. **That migration is not complete yet.** The chart script can publish chart packages, but the Argo Applications currently use Git paths; no addon image-mirror workflow or ECR image overrides are configured.

Complete and validate these steps before describing the cluster as private-registry-only:

1. Create ECR repositories for each pinned chart and each upstream container image. Keep immutable version/digest tags, scan on push, and apply retention policies.
2. Publish the pinned `.tgz` charts with `bash scripts/mirror-addon-charts.sh push` from an AWS-authenticated machine. The default chart location is `ACCOUNT.dkr.ecr.eu-central-1.amazonaws.com/eks-platform-demo/addon-charts/<chart>`.
3. Mirror all rendered images, preserving multi-platform manifests and recording source and destination digests. Add chart-specific ECR image overrides to each dev/QA values file.
4. Configure Argo CD to read the OCI charts from ECR and authenticate using a renewable ECR token flow. ECR login passwords expire; do not commit a generated password or treat a one-time login as durable credentials.
5. Test a clean Argo sync and node image pull, then remove the Git chart source only after the ECR source is healthy.

The nodes already need ECR pull permission for app images. Confirm the node roles also have pull access to every addon-image repository, especially if repositories use different accounts.

`storage-gp3` is not a chart. Its Application applies `platform/storage/gp3-encrypted.yaml`, which defines an encrypted, non-default EBS `gp3` StorageClass named `gp3-encrypted`. A workload must request a PVC using that class to provision a volume; simply installing the StorageClass does not create a disk.

Other non-chart addon resources are also managed from manifests, not Helm values. Look under `platform/addons/dev/default-namespace-security/`, `external-secrets-config/`, and `karpenter-config/` (and the corresponding `qa/` directories).