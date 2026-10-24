# kagent dev troubleshooting assistant

kagent is prepared in `platform/proposals/kagent/dev/` as a private, read-only
assistant for the dev EKS cluster. It can inspect Kubernetes objects, events
and pod logs; Argo CD Application health; Velero backup resources; Grafana
dashboards and data sources; and Prometheus metrics. It cannot change cluster
resources through the tools bound to the agent.

## What it can inspect

- Kubernetes resources and pod logs in the configured project namespaces,
  including `argocd`, `default`, `ingress-nginx`, `monitoring`, `velero`,
  `kube-system`, `cert-manager`, `external-secrets`, and `kagent`.
- Argo CD Applications and ApplicationSets, including sync and health status.
- Velero backups, schedules, restores, backup storage locations, and related
  namespaced resources.
- OpenTelemetry Collector resources and its pod logs. The collector sends
  traces to Tempo, metrics to Prometheus, and logs only to its debug exporter.
- Prometheus queries and metric metadata through Grafana's MCP server, plus
  Grafana dashboard and data source lookups.

The project does not currently run Loki, so the assistant cannot query a
central log store. The configured Grafana MCP tools do not query Tempo traces;
the agent can inspect Tempo resources and Collector logs/configuration, but
direct trace search is not enabled. Grafana, Prometheus, and the Collector are
configured with zero replicas when the dev stack is paused. Their MCP queries
will work once the stack is resumed and those services are running.

## Access controls

- kagent and its CRDs are pinned to `0.10.3`, the version used for the
  Kubernetes 1.33 dev cluster. Recheck compatibility before changing versions.
- The Kubernetes tool server uses `--read-only` and namespace-scoped
  `get/list/watch` permissions. Kubernetes Secret access is disabled.
- The agent is bound to an explicit read-only list of Kubernetes, Prometheus,
  and Grafana MCP tools. Dashboard updates, alert changes, resource changes,
  Helm, and AWS MCP tools are not bound to the agent.
- kagent 0.x also supplies built-in local tools, including shell and file
  helpers. The system prompt tells the assistant not to use them, and the
  agent's ServiceAccount has token mounting disabled and no RoleBinding. This
  prevents that shell from using Kubernetes credentials, but the prompt is not
  an enforcement boundary for local process access. Use a dedicated OpenAI key
  with a low spend limit, and treat this as a dev assistant rather than a
  production security boundary.
- Grafana MCP is pinned to image `grafana/mcp-grafana:1.5.0`; keep its discovered
  tool list aligned with the explicit read-only allowlist in the Agent.
- Grafana access uses a Grafana service-account token with Viewer permissions.
  The token and OpenAI key are delivered from AWS Secrets Manager through
  External Secrets; neither value belongs in Git or Helm values.
- The kagent UI has no public Ingress. Use an authenticated workstation and
  local `kubectl port-forward` only. Authentication inside the UI is not
  configured, so do not expose its Service beyond the cluster.

These controls apply to the configured tools and Kubernetes identity. Verify
the rendered ServiceAccounts and RoleBindings after installation before using
the agent with real operational data.

## Activate in dev

The manifests stay outside the auto-discovered Argo CD paths. This keeps a Git
push from installing kagent by itself. After merging or pushing this branch,
activate each Argo CD Application manually in this order:

1. Create the OpenAI API key in Account B's AWS Secrets Manager as
   `eks-platform-demo/dev/kagent-openai`, with property `OPENAI_API_KEY`.
2. Create a Grafana service account with Viewer permissions. Store its token
   in AWS Secrets Manager as `eks-platform-demo/dev/kagent-grafana-readonly`,
   with property `GRAFANA_SERVICE_ACCOUNT_TOKEN`.
3. Confirm the `aws-secrets-manager` ClusterSecretStore is Ready and can read
   both paths. Make sure the dev cluster is resumed.
4. Apply the CRD Application and wait for it to become Synced and Healthy. It
   also creates the `kagent` namespace:

   ```bash
   kubectl --context dev apply -f platform/proposals/kagent/dev/kagent-crds-application.yaml
   kubectl --context dev -n argocd get application kagent-crds
   ```

5. Apply the secrets Application and manually Sync it. Wait for both
   ExternalSecrets and the resulting Kubernetes Secrets to be Ready before
   installing the controller; this avoids starting kagent with missing keys:

   ```bash
   kubectl --context dev apply -f platform/proposals/kagent/dev/kagent-secrets-application.yaml
   kubectl --context dev -n argocd get application kagent-secrets
   kubectl --context dev -n kagent get externalsecrets,secrets
   ```

6. Apply the controller Application, manually Sync it in Argo CD, and wait
   until it is Synced and Healthy:

   ```bash
   kubectl --context dev apply -f platform/proposals/kagent/dev/kagent-application.yaml
   kubectl --context dev -n argocd get application kagent
   ```

7. Apply the agent resources Application and manually Sync it:

   ```bash
   kubectl --context dev apply -f platform/proposals/kagent/dev/kagent-resources-application.yaml
   kubectl --context dev -n argocd get application kagent-resources
   kubectl --context dev -n kagent get externalsecrets,secrets,agents,remotemcpservers
   ```

8. Confirm both ExternalSecrets are Ready, the agent is Ready, and
   `kagent-grafana-mcp` has discovered its tools. Then open the private UI:

   ```bash
   kubectl --context dev -n kagent port-forward svc/kagent-ui 8080:8080
   ```

   Visit `http://localhost:8080` while the port-forward is running.

## Check permissions and behaviour

Before relying on the assistant, inspect its Kubernetes ServiceAccounts,
Roles, and RoleBindings. Confirm the tool server has no write verbs and no
Secret access, and that its namespace Roles match the list above. Confirm the
Grafana service account has Viewer permissions. Ask it to inspect a known pod,
read its logs, summarize an Argo CD Application, list Velero backup status,
look up a Grafana dashboard, and run a simple PromQL query. Do not use it to
apply fixes; make changes through Git and Argo CD after human review.

## Files and upstream references

The implementation, chart values, activation Applications, and agent
definition are in [the kagent dev directory](../platform/proposals/kagent/dev/README.md).
The kagent 0.x line is used because the current dev cluster runs Kubernetes
1.33; confirm the [version support](https://www.kagent.dev/docs/kagent/1.x/reference/versions/)
and [Helm chart settings](https://www.kagent.dev/docs/kagent/0.x/resources/helm/)
before upgrading. Available tools are documented in the [kagent tools
reference](https://www.kagent.dev/docs/kagent/0.x/resources/tools-ecosystem/).
