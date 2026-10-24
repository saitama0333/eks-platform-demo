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

The dev EKS cluster currently runs Kubernetes 1.33. The kagent 1.x install
guide currently requires Kubernetes 1.37 or later and the
`certificates.k8s.io/v1beta1` API. That makes the 1.x line unsuitable for this
cluster today. The 0.x documentation currently lists 0.10.3 and provides a
Helm install path; the proposal manifests use that pinned version as a dev
trial only. The 0.x and 1.x lines are not an in-place upgrade path, so review
the migration plan before moving to 1.x.

The proposal is kept in `platform/proposals/kagent/dev/`, outside the paths
that the dev root Application discovers. Nothing is installed or synced from
these files automatically. First review the proposal, create the model API key
in AWS Secrets Manager, and then activate it deliberately in dev. Recheck the
upstream compatibility and chart values before that rollout.

## Proposed first use

- The first manifest enables Kubernetes inspection only. The built-in Argo
  tools refer to Argo Rollouts, not Argo CD, and the Prometheus integration
  needs a separate review of its available tools and credentials.
- Let it read only the namespaces needed for the investigation: `argocd`,
  `default`, `ingress-nginx`, and `monitoring`.
- Use a model-provider key stored through External Secrets; do not put API keys
  in Git or Helm values.
- Keep the UI private and reach it only through a local port-forward from a
  trusted workstation. Do not expose the default UI or MCP endpoint publicly.
- Do not grant write tools, shell access, `kubectl apply`, deletion, scaling,
  Terraform, or AWS API access. Any proposed fix should be reviewed and made
  through Git, then applied by Argo CD.
- Add resource requests/limits and monitor the extra controller, database,
  substrate workers, and model API usage before using it on the already-small
  dev capacity.

kagent separates the agent definition from its runtime and uses MCP servers
to give agents tools. The proposal sets both the tool server's `--read-only`
flag and read-only, namespace-scoped Kubernetes RBAC, with Secret access
disabled. The agent itself is bound only to read tools. These layers reduce
the chance of an accidental change; they do not replace a human review.

The controller UI has no public ingress in the proposal. After installation,
access it only with `kubectl port-forward` from an authenticated workstation.
The initial manifest has no Prometheus, Grafana, AWS, shell, or Argo CD access.
Those can be considered after the Kubernetes-only trial works.

See [the proposal README](../platform/proposals/kagent/dev/README.md) for the
manifest list, prerequisites, and later dev activation steps.

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
- [kagent 0.x installation](https://kagent.dev/docs/kagent/0.x/introduction/installation/)
- [kagent 0.x Helm chart reference](https://kagent.dev/docs/kagent/0.x/resources/helm/)
- [kagent 0.x tools ecosystem](https://www.kagent.dev/docs/kagent/0.x/resources/tools-ecosystem/)
- [kagent 1.x installation requirements](https://kagent.dev/docs/kagent/1.x/setup/installation/)
- [kagent version support](https://kagent.dev/docs/kagent/1.x/reference/versions/)
