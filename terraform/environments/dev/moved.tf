# The provider became count-managed so either environment can own the single
# account-wide GitHub OIDC provider and the other can reuse its ARN.
moved {
  from = module.container_registry.aws_ecr_repository.apps
  to   = module.ecr.aws_ecr_repository.apps
}

moved {
  from = module.container_registry.aws_iam_openid_connect_provider.github
  to   = module.ecr.aws_iam_openid_connect_provider.github[0]
}

moved {
  from = module.container_registry.aws_ecr_lifecycle_policy.apps
  to   = module.ecr.aws_ecr_lifecycle_policy.apps
}

moved {
  from = module.container_registry.aws_iam_role.github_actions_ecr
  to   = module.ecr.aws_iam_role.github_actions_ecr
}

moved {
  from = module.container_registry.aws_iam_role_policy.github_actions_ecr
  to   = module.ecr.aws_iam_role_policy.github_actions_ecr
}
