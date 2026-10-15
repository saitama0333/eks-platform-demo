data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  interruption_queue_name = "${var.cluster_name}-karpenter"

  interruption_events = {
    scheduled_change = {
      source      = ["aws.health"]
      detail_type = ["AWS Health Event"]
    }

    spot_interruption = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Spot Instance Interruption Warning"]
    }

    rebalance = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance Rebalance Recommendation"]
    }

    instance_state_change = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance State-change Notification"]
    }

    capacity_reservation = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Capacity Reservation Instance Interruption Warning"]
    }
  }
}

#
# --------------------------------------------------------------------------
# SQS INTERRUPTION QUEUE
# --------------------------------------------------------------------------
#

resource "aws_sqs_queue" "karpenter_interruption" {
  name = local.interruption_queue_name

  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

#
# --------------------------------------------------------------------------
# EVENTBRIDGE INTERRUPTION RULES
# --------------------------------------------------------------------------
#

resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each = local.interruption_events

  name        = substr("${var.cluster_name}-karpenter-${each.key}", 0, 64)
  description = "Karpenter interruption event - ${each.key}"

  event_pattern = jsonencode({
    source = each.value.source

    "detail-type" = each.value.detail_type
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each = local.interruption_events

  rule = aws_cloudwatch_event_rule.karpenter_interruption[each.key].name
  arn  = aws_sqs_queue.karpenter_interruption.arn

  target_id = "KarpenterInterruptionQueue"
}

#
# --------------------------------------------------------------------------
# SQS QUEUE POLICY
# --------------------------------------------------------------------------
#

data "aws_iam_policy_document" "karpenter_queue" {
  statement {
    sid    = "AllowEventBridgeToSendMessage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = [
      "sqs:SendMessage"
    ]

    resources = [
      aws_sqs_queue.karpenter_interruption.arn
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"

      values = [
        for rule in aws_cloudwatch_event_rule.karpenter_interruption :
        rule.arn
      ]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "sqs:*"
    ]

    resources = [
      aws_sqs_queue.karpenter_interruption.arn
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"

      values = [
        "false"
      ]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url
  policy    = data.aws_iam_policy_document.karpenter_queue.json
}

#
# --------------------------------------------------------------------------
# KARPENTER NODE IAM ROLE
# --------------------------------------------------------------------------
#

data "aws_iam_policy_document" "karpenter_node_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "ec2.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "KarpenterNodeRole-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

#
# --------------------------------------------------------------------------
# EKS ACCESS ENTRY FOR KARPENTER NODES
# --------------------------------------------------------------------------
#

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  depends_on = [
    aws_iam_role.karpenter_node
  ]
}

#
# --------------------------------------------------------------------------
# KARPENTER CONTROLLER IAM ROLE
# --------------------------------------------------------------------------
#

data "aws_iam_policy_document" "karpenter_controller_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "pods.eks.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "KarpenterControllerRole-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role.json

  tags = var.tags
}

#
# --------------------------------------------------------------------------
# KARPENTER CONTROLLER POLICY
# --------------------------------------------------------------------------
#

data "aws_iam_policy_document" "karpenter_controller" {

  #
  # EC2 resource access required during RunInstances/CreateFleet
  #

  statement {
    sid    = "AllowScopedEC2InstanceAccessActions"
    effect = "Allow"

    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::image/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::snapshot/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:security-group/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:subnet/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:capacity-reservation/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:placement-group/*"
    ]
  }

  #
  # Karpenter-created launch templates
  #

  statement {
    sid    = "AllowScopedEC2LaunchTemplateAccessActions"
    effect = "Allow"

    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:launch-template/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"

      values = [
        "*"
      ]
    }
  }

  #
  # Resource creation
  #

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"

    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:fleet/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:instance/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:volume/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:network-interface/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:launch-template/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:spot-instances-request/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"

      values = [
        var.cluster_name
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"

      values = [
        "*"
      ]
    }
  }

  #
  # Tags created together with resources
  #

  statement {
    sid    = "AllowScopedResourceCreationTagging"
    effect = "Allow"

    actions = [
      "ec2:CreateTags"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:fleet/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:instance/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:volume/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:network-interface/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:launch-template/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:spot-instances-request/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"

      values = [
        var.cluster_name
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"

      values = [
        "RunInstances",
        "CreateFleet",
        "CreateLaunchTemplate"
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"

      values = [
        "*"
      ]
    }
  }

  #
  # Tag existing Karpenter-managed instances
  #

  statement {
    sid    = "AllowScopedResourceTagging"
    effect = "Allow"

    actions = [
      "ec2:CreateTags"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:instance/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"

      values = [
        "*"
      ]
    }

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/eks:eks-cluster-name"

      values = [
        var.cluster_name
      ]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"

      values = [
        "eks:eks-cluster-name",
        "karpenter.sh/nodeclaim",
        "Name"
      ]
    }
  }

  #
  # Delete Karpenter-managed instances and launch templates
  #

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"

    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:instance/*",
      "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:launch-template/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"

      values = [
        "*"
      ]
    }
  }

  #
  # IAM PassRole
  #

  statement {
    sid    = "AllowPassingInstanceRole"
    effect = "Allow"

    actions = [
      "iam:PassRole"
    ]

    resources = [
      aws_iam_role.karpenter_node.arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"

      values = [
        "ec2.amazonaws.com",
        "ec2.amazonaws.com.cn"
      ]
    }
  }

  #
  # Instance profile creation
  #

  statement {
    sid    = "AllowScopedInstanceProfileCreationActions"
    effect = "Allow"

    actions = [
      "iam:CreateInstanceProfile"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"

      values = [
        var.cluster_name
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"

      values = [
        var.aws_region
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"

      values = [
        "*"
      ]
    }
  }

  #
  # Instance profile tagging
  #

  statement {
    sid    = "AllowScopedInstanceProfileTagActions"
    effect = "Allow"

    actions = [
      "iam:TagInstanceProfile"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"

      values = [
        var.aws_region
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"

      values = [
        var.cluster_name
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"

      values = [
        var.aws_region
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"

      values = [
        "*"
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"

      values = [
        "*"
      ]
    }
  }

  #
  # Instance profile management
  #

  statement {
    sid    = "AllowScopedInstanceProfileActions"
    effect = "Allow"

    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"

      values = [
        "owned"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"

      values = [
        var.aws_region
      ]
    }

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"

      values = [
        "*"
      ]
    }
  }

  #
  # Instance profile reads
  #

  statement {
    sid    = "AllowUnscopedInstanceProfileListAction"
    effect = "Allow"

    actions = [
      "iam:ListInstanceProfiles"
    ]

    resources = [
      "*"
    ]
  }

  statement {
    sid    = "AllowInstanceProfileReadActions"
    effect = "Allow"

    actions = [
      "iam:GetInstanceProfile"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
    ]
  }

  #
  # EKS cluster discovery
  #

  statement {
    sid    = "AllowAPIServerEndpointDiscovery"
    effect = "Allow"

    actions = [
      "eks:DescribeCluster"
    ]

    resources = [
      var.cluster_arn
    ]
  }

  #
  # Interruption queue
  #

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"

    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage"
    ]

    resources = [
      aws_sqs_queue.karpenter_interruption.arn
    ]
  }

  #
  # Regional resource discovery
  #

  statement {
    sid    = "AllowRegionalReadActions"
    effect = "Allow"

    actions = [
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribePlacementGroups",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets"
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"

      values = [
        var.aws_region
      ]
    }
  }

  #
  # SSM AMI metadata
  #

  statement {
    sid    = "AllowSSMReadActions"
    effect = "Allow"

    actions = [
      "ssm:GetParameter"
    ]

    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::parameter/aws/service/*"
    ]
  }

  #
  # Pricing
  #

  statement {
    sid    = "AllowPricingReadActions"
    effect = "Allow"

    actions = [
      "pricing:GetProducts"
    ]

    resources = [
      "*"
    ]
  }

  #
  # Zonal Shift
  #
  # Karpenter 1.12+ supports this permission. We are not enabling
  # Zonal Shift in Helm yet, but keeping the permission makes the
  # controller role compatible with the current Karpenter policy model.
  #

  statement {
    sid    = "AllowZonalShiftStatusReadOnly"
    effect = "Allow"

    actions = [
      "arc-zonal-shift:GetManagedResource"
    ]

    resources = [
      "*"
    ]

    condition {
      test     = "StringEquals"
      variable = "arc-zonal-shift:ResourceIdentifier"

      values = [
        var.cluster_arn
      ]
    }
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "KarpenterControllerPolicy"
  role   = aws_iam_role.karpenter_controller.id
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

#
# --------------------------------------------------------------------------
# EKS POD IDENTITY
# --------------------------------------------------------------------------
#

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "karpenter"

  role_arn = aws_iam_role.karpenter_controller.arn

  depends_on = [
    aws_iam_role.karpenter_controller
  ]
}