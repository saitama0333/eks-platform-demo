# Terraform-managed Helm releases for the isolated QA cluster.

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

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.14.0"
  namespace  = "kube-system"

  wait    = true
  timeout = 600

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
      value = module.vpc.vpc_id
    }
  ]

  depends_on = [module.eks]
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
        additionalDataSources = [
          {
            name      = "Tempo"
            type      = "tempo"
            access    = "proxy"
            url       = "http://tempo.monitoring.svc.cluster.local:3100"
            isDefault = false
          }
        ]
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

  depends_on = [module.eks]
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.6.2"
  namespace  = "kube-system"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = "karpenter"
      }
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.interruption_queue_name
      }
      controller = {
        resources = {
          requests = { cpu = "200m", memory = "256Mi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
      }
    })
  ]

  depends_on = [module.karpenter]
}

# The bucket is derived from this AWS account by platform_aws.
resource "helm_release" "velero" {
  name       = "velero"
  repository = "https://vmware-tanzu.github.io/helm-charts"
  chart      = "velero"
  version    = "8.6.0"
  namespace  = "velero"

  create_namespace = true
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      serviceAccount = {
        server = {
          create = true
          name   = "velero"
        }
      }
      credentials = {
        useSecret = false
      }
      configuration = {
        backupStorageLocation = [
          {
            name     = "default"
            provider = "aws"
            bucket   = module.platform_aws.velero_bucket_name
            config = {
              region = var.aws_region
            }
          }
        ]
        volumeSnapshotLocation = []
        uploaderType           = "kopia"
      }
      snapshotsEnabled = false
      deployNodeAgent  = true
      initContainers = [
        {
          name            = "velero-plugin-for-aws"
          image           = "velero/velero-plugin-for-aws:v1.10.0"
          imagePullPolicy = "IfNotPresent"
          volumeMounts = [
            {
              mountPath = "/target"
              name      = "plugins"
            }
          ]
        }
      ]
      schedules = {
        daily = {
          schedule = "0 2 * * *"
          template = {
            ttl                = "168h"
            includedNamespaces = ["default"]
          }
        }
      }
    })
  ]

  depends_on = [module.platform_aws]
}
