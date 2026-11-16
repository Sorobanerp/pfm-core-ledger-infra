terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "pfm-platform-prod"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "kms_crypto_key_id" {
  description = "Cloud KMS CryptoKey ID for Tenant Envelope Encryption"
  type        = string
  default     = "projects/pfm-platform-prod/locations/southamerica-east1/keyRings/pfm-ledger-kr/cryptoKeys/pfm-tenant-master-key"
}

resource "google_service_account" "pfm_core_ledger_sa" {
  project      = var.project_id
  account_id   = "pfm-core-ledger-java-${var.environment}"
  display_name = "PFM Core Ledger Java Service Account (Least Privilege)"
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.pfm_core_ledger_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[pfm-platform/pfm-core-ledger-sa]"
}

resource "google_project_iam_member" "cloudsql_core_ledger_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.pfm_core_ledger_sa.email}"
}

resource "google_kms_crypto_key_iam_member" "tenant_kms_encrypter_decrypter" {
  crypto_key_id = var.kms_crypto_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.pfm_core_ledger_sa.email}"
}

output "gcp_service_account_email" {
  value = google_service_account.pfm_core_ledger_sa.email
}
