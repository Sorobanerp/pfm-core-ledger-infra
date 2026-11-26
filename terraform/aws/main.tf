terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.33"
    }
  }
}

variable "environment" {
  description = "Deployment environment (local, staging, prod)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region (Ohio)"
  type        = string
  default     = "us-east-2"
}

variable "compute_engine" {
  description = "Compute engine for workloads: ecs_fargate_spot (ADR-008 Pilot) or eks"
  type        = string
  default     = "ecs_fargate_spot"
}

variable "shared_state_bucket" {
  description = "S3 bucket storing pfm-shared-infra remote state"
  type        = string
  default     = "sorobanerp-pfm-tfstate-us-east-2-366476833548"
}

variable "image_repository" {
  description = "Container image repository"
  type        = string
  default     = "public.ecr.aws/docker/library/busybox"
}

variable "image_tag" {
  description = "Container image tag"
  type        = string
  default     = "1.36"
}

variable "eks_cluster_name" {
  description = "Optional override for EKS cluster name"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_arn" {
  description = "Optional override for EKS OIDC Provider ARN for IRSA"
  type        = string
  default     = ""
}

variable "eks_oidc_issuer_url" {
  description = "Optional override for EKS OIDC Issuer URL without https://"
  type        = string
  default     = ""
}

variable "rds_core_ledger_resource_id" {
  description = "Optional override for RDS DB instance resource ID for pfm_core_ledger"
  type        = string
  default     = ""
}

variable "msk_cluster_arn" {
  description = "MSK Cluster ARN for Kafka topic-level IAM access"
  type        = string
  default     = "arn:aws:kafka:us-east-2:000000000000:cluster/pfm-kafka/00000000-0000-0000-0000-000000000001-1"
}

variable "tenant_kms_key_arn" {
  description = "Optional override for KMS Master Key ARN for Tenant Envelope Encryption (DEK/KEK)"
  type        = string
  default     = ""
}

provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = var.shared_state_bucket
    key    = "pfm-shared-infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  eks_cluster_name            = coalesce(var.eks_cluster_name, try(data.terraform_remote_state.shared.outputs.eks_cluster_name, "pfm-eks-prod"))
  eks_oidc_provider_arn       = try(coalesce(var.eks_oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, null)), "")
  eks_oidc_issuer_url         = try(coalesce(var.eks_oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, null)), "")
  rds_core_ledger_resource_id = coalesce(var.rds_core_ledger_resource_id, try(data.terraform_remote_state.shared.outputs.rds_resource_id, "db-PFMCORELEDGER01"))
  tenant_kms_key_arn          = coalesce(var.tenant_kms_key_arn, try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, "arn:aws:kms:us-east-2:366476833548:alias/pfm-master-key"))

  # ECS Pilot Locals
  ecs_cluster_arn             = try(data.terraform_remote_state.shared.outputs.ecs_cluster_arn, "arn:aws:ecs:us-east-2:366476833548:cluster/pfm-pilot-prod")
  ecs_cluster_name            = try(data.terraform_remote_state.shared.outputs.ecs_cluster_name, "pfm-pilot-prod")
  ecs_tasks_security_group_id = try(data.terraform_remote_state.shared.outputs.ecs_tasks_security_group_id, "")
  cloud_map_namespace_arn     = try(data.terraform_remote_state.shared.outputs.cloud_map_namespace_arn, "")
  public_subnet_ids           = try(data.terraform_remote_state.shared.outputs.public_subnet_ids, [])
  private_subnet_ids          = try(data.terraform_remote_state.shared.outputs.private_subnet_ids, [])
  task_subnet_ids             = length(local.public_subnet_ids) > 0 ? local.public_subnet_ids : local.private_subnet_ids
  upstash_kafka_secret_arn    = try(data.terraform_remote_state.shared.outputs.upstash_kafka_secret_arn, "")
}

# =============================================================================
# Amazon ECS Fargate Spot & Service Connect Pilot (ADR-008)
# =============================================================================

resource "aws_iam_role" "ecs_execution_role" {
  count       = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name        = "pfm-core-ledger-ecs-exec-${var.environment}"
  description = "ECS Task Execution Role for pfm-core-ledger (ECR, CloudWatch, Secrets)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  count      = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  role       = aws_iam_role.ecs_execution_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  count       = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name        = "pfm-core-ledger-ecs-task-${var.environment}"
  description = "Least Privilege Task Role for pfm-core-ledger-java (RDS IAM, KMS, Upstash)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_least_privilege" {
  count = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name  = "pfm-core-ledger-ecs-task-policy"
  role  = aws_iam_role.ecs_task_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PostgreSQLCoreLedgerRdsIamConnect"
        Effect = "Allow"
        Action = ["rds-db:connect"]
        Resource = [
          "arn:aws:rds-db:${var.aws_region}:*:dbuser:${local.rds_core_ledger_resource_id}/pfm_app_user"
        ]
      },
      {
        Sid    = "TenantEnvelopeEncryptionKmsAccess"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [local.tenant_kms_key_arn]
      },
      {
        Sid    = "UpstashKafkaSecretsAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = ["arn:aws:secretsmanager:${var.aws_region}:*:secret:pfm/upstash/*"]
      }
    ]
  })
}

variable "enable_cloudwatch_logs" {
  description = "Disable AWS CloudWatch Logs by default (FinOps ADR-010: use Datadog JSON stdout / FireLens instead of CloudWatch)"
  type        = bool
  default     = false
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  count             = var.compute_engine == "ecs_fargate_spot" && var.enable_cloudwatch_logs ? 1 : 0
  name              = "/ecs/pfm-core-ledger-java-${var.environment}"
  retention_in_days = 7

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_ecs_task_definition" "service" {
  count                    = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  family                   = "pfm-core-ledger-java-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role[0].arn
  task_role_arn            = aws_iam_role.ecs_task_role[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "pfm-core-ledger-java"
      image     = "${var.image_repository}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          name          = "grpc"
          containerPort = 18200
          hostPort      = 18200
          protocol      = "tcp"
        }
      ]
      logConfiguration = var.enable_cloudwatch_logs ? {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ledger"
        }
      } : null
      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = "prod,ecs-pilot" },
        { name = "AWS_CLOUDWATCH_ENABLED", value = "false" },
        { name = "SERVER_PORT", value = "18200" }
      ]
    }
  ])

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_ecs_service" "service" {
  count           = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name            = "pfm-core-ledger-java"
  cluster         = local.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.service[0].arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 0
  }

  network_configuration {
    subnets          = local.task_subnet_ids
    security_groups  = local.ecs_tasks_security_group_id != "" ? [local.ecs_tasks_security_group_id] : []
    assign_public_ip = true
  }

  dynamic "service_connect_configuration" {
    for_each = local.cloud_map_namespace_arn != "" ? [1] : []
    content {
      enabled   = true
      namespace = local.cloud_map_namespace_arn
      service {
        port_name      = "grpc"
        discovery_name = "pfm-core-ledger-java"
        client_alias {
          port     = 18200
          dns_name = "pfm-core-ledger-java.pfm.internal"
        }
      }
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_appautoscaling_target" "ecs_target" {
  count              = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${local.ecs_cluster_name}/${aws_ecs_service.service[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu_policy" {
  count              = var.compute_engine == "ecs_fargate_spot" ? 1 : 0
  name               = "pfm-core-ledger-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target[0].service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# =============================================================================
# EKS / Kubernetes Support (Optional / Legacy when compute_engine = "eks")
# =============================================================================

data "aws_eks_cluster" "eks" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "eks" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = var.compute_engine == "eks" ? data.aws_eks_cluster.eks[0].endpoint : "https://127.0.0.1"
  cluster_ca_certificate = var.compute_engine == "eks" ? base64decode(data.aws_eks_cluster.eks[0].certificate_authority[0].data) : ""
  token                  = var.compute_engine == "eks" ? data.aws_eks_cluster_auth.eks[0].token : ""
}

provider "helm" {
  kubernetes {
    host                   = var.compute_engine == "eks" ? data.aws_eks_cluster.eks[0].endpoint : "https://127.0.0.1"
    cluster_ca_certificate = var.compute_engine == "eks" ? base64decode(data.aws_eks_cluster.eks[0].certificate_authority[0].data) : ""
    token                  = var.compute_engine == "eks" ? data.aws_eks_cluster_auth.eks[0].token : ""
  }
}

resource "aws_iam_role" "pfm_core_ledger_irsa_role" {
  count       = var.compute_engine == "eks" ? 1 : 0
  name        = "pfm-core-ledger-java-irsa-${var.environment}"
  description = "IRSA Role exclusively for pfm-core-ledger-java (Least Privilege ADR-006)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.eks_oidc_issuer_url}:sub" = "system:serviceaccount:pfm-platform:pfm-core-ledger-sa"
            "${local.eks_oidc_issuer_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "pfm_core_ledger_least_privilege" {
  count = var.compute_engine == "eks" ? 1 : 0
  name  = "pfm-core-ledger-java-least-privilege-policy"
  role  = aws_iam_role.pfm_core_ledger_irsa_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PostgreSQLCoreLedgerRdsIamConnect"
        Effect = "Allow"
        Action = ["rds-db:connect"]
        Resource = [
          "arn:aws:rds-db:${var.aws_region}:*:dbuser:${local.rds_core_ledger_resource_id}/pfm_app_user"
        ]
      },
      {
        Sid    = "TenantEnvelopeEncryptionKmsAccess"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [local.tenant_kms_key_arn]
      }
    ]
  })
}

resource "kubernetes_service_account_v1" "pfm_core_ledger_sa" {
  count = var.compute_engine == "eks" ? 1 : 0
  metadata {
    name      = "pfm-core-ledger-sa"
    namespace = "pfm-platform"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.pfm_core_ledger_irsa_role[0].arn
    }
  }
}

resource "helm_release" "pfm_core_ledger" {
  count            = var.compute_engine == "eks" ? 1 : 0
  name             = "pfm-core-ledger-java"
  chart            = "${path.module}/../../helm"
  namespace        = "pfm-platform"
  create_namespace = false
  wait             = false
  values           = [file("${path.module}/../../helm/values-prod.yaml")]

  set {
    name  = "replicaCount"
    value = "1"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account_v1.pfm_core_ledger_sa[0].metadata[0].name
  }

  depends_on = [kubernetes_service_account_v1.pfm_core_ledger_sa]
}

output "irsa_role_arn" {
  description = "IAM Role ARN for pfm-core-ledger-java ServiceAccount"
  value       = try(aws_iam_role.pfm_core_ledger_irsa_role[0].arn, "")
}

output "ecs_service_name" {
  description = "ECS Service Name"
  value       = try(aws_ecs_service.service[0].name, "")
}

output "ecs_task_definition_arn" {
  description = "ECS Task Definition ARN"
  value       = try(aws_ecs_task_definition.service[0].arn, "")
}
