# kagent read-only trial for dev

These files are a proposal. The current dev Argo CD root does not scan this
folder, so they will not install kagent by themselves.

The proposal pins kagent and its CRDs to `0.10.3`. It is intended for a
controlled dev trial on the current Kubernetes 1.33 cluster. Upstream kagent
1.x currently requires Kubernetes 1.37 or later, and 0.x is not an in-place
upgrade path to 1.x. Review upstream docs and the chart values again before
using these manifests.

## What is included

- `kagent-crds-application.yaml`: installs the kagent 0.10.3 CRDs.
- `kagent-application.yaml` and `values.yaml`: installs one controller, its
  bundled dev database and the Kubernetes tool server. Example agents and
  optional tools are disabled.
- `kagent-resources-application.yaml` and `kagent-resources.yaml`: add the
  ExternalSecret for the model API key and define a read-only Kubernetes
  troubleshooting agent.

The tool server has only Kubernetes tools enabled, uses `--read-only`, has
namespace-scoped `get/list/watch` RBAC and cannot read Kubernetes Secrets. The
agent is bound only to resource listing, describe, logs and events tools. It
cannot change cluster resources. The scope includes `argocd`, `default`,
`ingress-nginx`, and `monitoring`.

Prometheus, Grafana, AWS APIs, Argo CD management, shell, and write access are
not included in this first trial. The controller UI has no Ingress. Access it
only with a local `kubectl port-forward` after installation.

## Before enabling in dev

1. Create an AWS Secrets Manager secret in Account B, region `eu-central-1`,
   named `eks-platform-demo/dev/kagent-openai`. It must contain the key
   `OPENAI_API_KEY`. Do not put the value in Git, a command line, or Helm
   values.
2. Confirm the External Secrets `ClusterSecretStore` named
   `aws-secrets-manager` is Ready and that its Pod Identity access allows this
   secret path.
3. Review the kagent 0.10.3 chart and CRDs, the RBAC scope, image versions,
   resource requests, and API cost. The bundled database is for development
   and evaluation only; do not use it as a production database.
4. Confirm all workload capacity needed for this trial is available. This
   cluster has used Karpenter and the managed node group, so watch node and pod
   capacity during installation.

## Deliberate activation sequence

After this proposal is merged to the branch Argo CD reads, use an
authenticated terminal and apply the files one at a time. These commands are
examples for the later dev rollout; they have not been run:

```bash
kubectl --context dev apply -f platform/proposals/kagent/dev/kagent-crds-application.yaml
kubectl --context dev -n argocd get application kagent-crds
```

The Application has no automatic sync policy. Start a manual Sync from the
Argo CD UI, then wait until `kagent-crds` is Synced and Healthy. After that,
install the controller:

```bash
kubectl --context dev apply -f platform/proposals/kagent/dev/kagent-application.yaml
kubectl --context dev -n argocd get application kagent
```

Start a manual Sync from the Argo CD UI and wait until `kagent` is Synced and
Healthy. Then add the resources Application:

```bash
kubectl --context dev apply -f platform/proposals/kagent/dev/kagent-resources-application.yaml
kubectl --context dev -n argocd get application kagent-resources
kubectl --context dev -n kagent get externalsecret,secret,agent
```

Start a manual Sync from the Argo CD UI. The `ExternalSecret` only syncs the
key after it exists in AWS Secrets Manager. Wait for the ExternalSecret to be
Ready and confirm the Secret exists before using the agent. The Agent refers
to the chart-created `default-model-config` and will not work until its API-key
secret is present.

Open the UI only from a local terminal:

```bash
kubectl --context dev -n kagent port-forward svc/kagent-ui 8080:8080
```

Then visit `http://localhost:8080`. Do not create an Ingress or public DNS
record for the UI during this trial.

## Checks after activation

- In `kagent`, confirm controller, tool server, UI, and agent pods are Ready.
- Inspect the tool server's ServiceAccount and Roles. It must have no write
  verbs and no Secret access.
- Ask the agent to inspect a pod that is Running, then a known failed pod. It
  should cite observed status, events, and log output and label any diagnosis
  as a likely cause.
- Ask it to scale or delete a resource. The available tool list and RBAC must
  prevent that action.
- Check node count, CPU/memory requests, logs, and model-provider usage.
- Remove the proposal applications and resources if the trial is not useful.

Do not move this folder under `platform/addons/dev/` until the review and dev
trial are complete. The root Application currently discovers only
`platform/addons/dev/**/application.yaml` and `platform/apps/dev/**/application.yaml`.
