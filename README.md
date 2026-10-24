# EKS platform demo

Terraform provisions separate dev and QA AWS foundations. Argo CD deploys and
reconciles Kubernetes platform services and sample applications from Git.
GitHub Actions is supported today; GitLab CI files are provided as an opt-in
alternative for validation and image publishing.

Start here:

- [Architecture and component reference](docs/ARCHITECTURE.md): what runs,
  how the pieces connect, and the current security and reliability boundaries.
- [Deployment and operations runbook](docs/DEPLOYMENT_RUNBOOK.md): launch,
  Terraform, image publishing, Argo CD, DNS/TLS, pause/resume, and recovery.
- [GitLab CI setup](.gitlab/README.md): pipeline stages, runner requirements,
  OIDC enablement, and required project variables.
- [kagent dev assistant](docs/KAGENT.md): read-only Kubernetes, monitoring,
  telemetry, and backup troubleshooting setup.

This is a useful dev/QA foundation, but it is not production-ready as
configured. The architecture guide records the specific gaps to review before
production use.
