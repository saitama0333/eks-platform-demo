# kagent for dev

This directory contains the ready-to-review kagent setup for the dev EKS
cluster. It is not under the paths scanned by the dev Argo CD root, so pushing
the branch does not install it automatically. Activate it using the steps in
[the kagent guide](../../../../docs/KAGENT.md).

## Included

- `kagent-crds-application.yaml`: installs the kagent `0.10.3` CRDs.
- `kagent-secrets-application.yaml` and `kagent-secrets.yaml`: create the
  ExternalSecrets before the controller chart starts, so its API key and
  Grafana MCP token are available at pod startup.
- `kagent-application.yaml` and `values.yaml`: install the controller, private
  UI, bundled development PostgreSQL, Kubernetes tool server, and Grafana MCP
  server. Optional sample agents and unrelated tools stay disabled.
- `kagent-resources-application.yaml` and `kagent-resources.yaml`: define the
  tokenless agent ServiceAccount and the `dev-troubleshooter` agent.

The agent can inspect Kubernetes resources, events, pod logs, Argo CD
Application status, Velero resources, Grafana dashboards/data sources, and
Prometheus metrics. OpenTelemetry Collector resources and logs can be inspected
through Kubernetes. This project has no Loki deployment, and the enabled MCP
tools do not query Tempo traces.

The Kubernetes tool server is configured with `--read-only`, namespace-scoped
RBAC, and no Kubernetes Secret access. The agent's explicit MCP tool list
excludes resource mutations, Helm, and AWS APIs. kagent 0.x also exposes local
built-in tools, including shell and file helpers. The agent prompt tells it not
to use these; its own ServiceAccount has token mounting disabled and no
RoleBinding, so local shell cannot use Kubernetes credentials. This is a dev
setup, not a production security boundary; use a dedicated OpenAI key with a
low spend limit. The Grafana MCP image is pinned to `1.5.0`. The UI has no
Ingress; access it through a local port-forward. The model key and Grafana
Viewer service account token must be available in AWS Secrets Manager as
described in the guide.

Both Git-backed Argo CD Applications point to the `test-kagent` branch. Change
their target revision when promoting this configuration to another branch.
