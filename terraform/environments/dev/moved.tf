# Preserve existing Helm release state while moving these resources from the
# EKS child module to this environment's shared helm.tf.
moved {
  from = module.eks.helm_release.argocd
  to   = helm_release.argocd
}

moved {
  from = module.eks.helm_release.aws_load_balancer_controller
  to   = helm_release.aws_load_balancer_controller
}

moved {
  from = module.eks.helm_release.kube_prometheus_stack
  to   = helm_release.kube_prometheus_stack
}

# The provider became count-managed so QA/prod roots can reuse the single
# account-wide GitHub OIDC provider created by dev.
moved {
  from = module.container_registry.aws_iam_openid_connect_provider.github
  to   = module.container_registry.aws_iam_openid_connect_provider.github[0]
}
