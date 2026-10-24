# kagent: read-only dev evaluation

## Short answer

kagent can fit this project as a Kubernetes troubleshooting helper. A first
agent could read pod status, events and logs, Argo CD Application health, and
Prometheus metrics, then explain likely causes and suggest the next check.
This can save time during incidents without giving an AI permission to change
the cluster.

This document is an evaluation only. It does not install kagent or change the
cluster.

## Why this is a separate evaluation

The dev EKS cluster currently runs Kubernetes 1.33. The current kagent 1.x
documentation lists `1.0.0-alpha16` and says its CI tests Kubernetes 1.35;
other Kubernetes versions are not exercised or guaranteed. This is not proof
that kagent cannot run on 1.33, but it is not enough evidence to add it to our
working cluster without a compatibility trial. The current 1.x install also
includes Agent Substrate and a database, so it adds more components than a
single small pod.

Before installing it on dev, check the upstream compatibility and release
status again, and try the pinned version on a disposable cluster or QA first.
Do not install it as part of the normal dev bootstrap until that trial is
successful.

## Proposed first use

- Keep the agent limited to Kubernetes inspection, Argo CD status, and
  Prometheus queries.
- Let it read only the namespaces needed for the investigation, such as
  `argocd`, `default`, and `monitoring`.
- Use a model-provider key stored through External Secrets; do not put API keys
  in Git or Helm values.
- Keep the UI private and use authenticated access. Do not expose the default
  MCP endpoint publicly.
- Do not grant write tools, shell access, `kubectl apply`, deletion, scaling,
  Terraform, or AWS API access. Any proposed fix should be reviewed and made
  through Git, then applied by Argo CD.
- Add resource requests/limits and monitor the extra controller, database,
  substrate workers, and model API usage before using it on the already-small
  dev capacity.

kagent separates the agent definition from its runtime and uses MCP servers
to give agents tools. Its tool server can expose Kubernetes, Argo, Helm, and
Prometheus functions. For a read-only deployment, both controls must be set:
disable write tools in the tool server and configure read-only Kubernetes
RBAC. Setting only one leaves a permission gap. Check the current kagent
documentation before writing manifests because the API and chart are changing
quickly.

## Suggested rollout gates

1. Confirm a kagent release supports the EKS Kubernetes version we run, or
   upgrade the dev cluster first.
2. Install it only in a non-production test cluster and pin all chart and
   image versions.
3. Verify the ServiceAccount cannot change resources, read Secrets, or access
   AWS; confirm it can read only the agreed namespaces and metrics.
4. Try troubleshooting scenarios using deliberately read-only tools. Compare
   its explanations with the actual events, logs, Argo status, and Prometheus
   query results.
5. Review resource use, LLM cost, authentication, logs, and retention before
   deciding whether to keep it.

## References

- [kagent overview](https://kagent.dev/docs/kagent/1.x/about/what-is-kagent/)
- [kagent version support](https://kagent.dev/docs/kagent/1.x/reference/versions/)
- [kagent tool catalog and read-only controls](https://kagent.dev/docs/kagent/1.x/reference/tools-ecosystem/)
- [kagent installation](https://kagent.dev/docs/kagent/1.x/setup/installation/)
