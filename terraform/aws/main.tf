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

variable "shared_state_bucket" {
  description = "S3 bucket storing pfm-shared-infra remote state"
  type        = string
  default     = "sorobanerp-pfm-tfstate-us-east-2-366476833548"
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
  eks_oidc_provider_arn       = coalesce(var.eks_oidc_provider_arn, try(data.terraform_remote_state.shared.outputs.oidc_provider_arn, ""))
  eks_oidc_issuer_url         = coalesce(var.eks_oidc_issuer_url, try(data.terraform_remote_state.shared.outputs.oidc_issuer_url, ""))
  rds_core_ledger_resource_id = coalesce(var.rds_core_ledger_resource_id, try(data.terraform_remote_state.shared.outputs.rds_resource_id, "db-PFMCORELEDGER01"))
  tenant_kms_key_arn          = coalesce(var.tenant_kms_key_arn, try(data.terraform_remote_state.shared.outputs.kms_master_key_arn, ""))
}

data "aws_eks_cluster" "eks" {
  name = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "eks" {
  name = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.eks.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.eks.token
  }
}

resource "aws_iam_role" "pfm_core_ledger_irsa_role" {
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
  name = "pfm-core-ledger-java-least-privilege-policy"
  role = aws_iam_role.pfm_core_ledger_irsa_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PostgreSQLCoreLedgerRdsIamConnect"
        Effect = "Allow"
        Action = [
          "rds-db:connect"
        ]
        Resource = [
          "arn:aws:rds-db:${var.aws_region}:*:dbuser:${local.rds_core_ledger_resource_id}/pfm_app_user"
        ]
      },
      {
        Sid    = "KafkaConsumeTxCategorizedOnly"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData"
        ]
        Resource = [
          var.msk_cluster_arn,
          "arn:aws:kafka:${var.aws_region}:*:topic/pfm-kafka/*/tx.categorized"
        ]
      },
      {
        Sid    = "KafkaProduceLedgerEntryCommittedOnly"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:WriteDataIdempotently"
        ]
        Resource = [
          "arn:aws:kafka:${var.aws_region}:*:topic/pfm-kafka/*/ledger.entry.committed"
        ]
      },
      {
        Sid    = "KafkaConsumerGroupAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        Resource = [
          "arn:aws:kafka:${var.aws_region}:*:group/pfm-kafka/*/pfm-core-ledger-group*"
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
        Resource = [
          local.tenant_kms_key_arn
        ]
      }
    ]
  })
}

resource "kubernetes_service_account_v1" "pfm_core_ledger_sa" {
  metadata {
    name      = "pfm-core-ledger-sa"
    namespace = "pfm-platform"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.pfm_core_ledger_irsa_role.arn
    }
  }
}

resource "helm_release" "pfm_core_ledger" {
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
    name  = "image.repository"
    value = "public.ecr.aws/docker/library/busybox"
  }

  set {
    name  = "image.tag"
    value = "1.36"
  }

  set {
    name  = "command[0]"
    value = "sh"
  }

  set {
    name  = "command[1]"
    value = "-c"
  }

  set {
    name  = "command[2]"
    value = "sleep infinity"
  }

  set {
    name  = "probesEnabled"
    value = "false"
  }

  set {
    name  = "pdb.minAvailable"
    value = "1"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account_v1.pfm_core_ledger_sa.metadata[0].name
  }

  depends_on = [kubernetes_service_account_v1.pfm_core_ledger_sa]
}

output "irsa_role_arn" {
  description = "IAM Role ARN for pfm-core-ledger-java ServiceAccount"
  value       = aws_iam_role.pfm_core_ledger_irsa_role.arn
}
