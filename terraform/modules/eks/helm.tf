resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  version = "1.14.0"

  depends_on = [
    aws_eks_pod_identity_association.aws_load_balancer_controller
  ]

  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      name  = "vpcId"
      value = var.vpc_id
    }
  ]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.9.2"

  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 600
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "91.5.1"

  namespace        = "monitoring"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      grafana = {
        enabled = true
      }

      prometheus = {
        prometheusSpec = {
          retention = "7d"
        }
      }

      alertmanager = {
        enabled = true
      }
    })
  ]
}

