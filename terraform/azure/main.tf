terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "resource_group_name" {
  description = "Azure Resource Group for pfm-core-ledger-java"
  type        = string
  default     = "rg-pfm-core-ledger"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "brazilsouth"
}

variable "aks_oidc_issuer_url" {
  description = "AKS OIDC Issuer URL for Workload Identity"
  type        = string
  default     = "https://brazilsouth.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/11111111-1111-1111-1111-111111111111/"
}

variable "postgres_core_ledger_scope" {
  description = "Resource ID of the isolated PostgreSQL Flexible Server database pfm_core_ledger"
  type        = string
  default     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pfm-core-ledger/providers/Microsoft.DBforPostgreSQL/flexibleServers/psql-pfm-core-ledger/databases/pfm_core_ledger"
}

variable "eventhub_tx_categorized_scope" {
  description = "Resource ID for Kafka-compatible Event Hub topic tx.categorized"
  type        = string
  default     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pfm-core-ledger/providers/Microsoft.EventHub/namespaces/eh-pfm-kafka/eventhubs/tx.categorized"
}

variable "eventhub_ledger_committed_scope" {
  description = "Resource ID for Kafka-compatible Event Hub topic ledger.entry.committed"
  type        = string
  default     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pfm-core-ledger/providers/Microsoft.EventHub/namespaces/eh-pfm-kafka/eventhubs/ledger.entry.committed"
}

variable "key_vault_tenant_kek_scope" {
  description = "Resource ID of Azure Key Vault key for tenant envelope encryption"
  type        = string
  default     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pfm-core-ledger/providers/Microsoft.KeyVault/vaults/kv-pfm-ledger/keys/pfm-tenant-master-key"
}

resource "azurerm_user_assigned_identity" "pfm_core_ledger_identity" {
  name                = "id-pfm-core-ledger-java-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_federated_identity_credential" "pfm_core_ledger_wi" {
  name                = "fic-pfm-core-ledger-java-${var.environment}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.pfm_core_ledger_identity.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:pfm-platform:pfm-core-ledger-sa"
}

resource "azurerm_role_assignment" "consume_tx_categorized" {
  scope                = var.eventhub_tx_categorized_scope
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = azurerm_user_assigned_identity.pfm_core_ledger_identity.principal_id
}

resource "azurerm_role_assignment" "produce_ledger_entry_committed" {
  scope                = var.eventhub_ledger_committed_scope
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_user_assigned_identity.pfm_core_ledger_identity.principal_id
}

resource "azurerm_role_assignment" "tenant_kms_crypto_user" {
  scope                = var.key_vault_tenant_kek_scope
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.pfm_core_ledger_identity.principal_id
}

output "workload_identity_client_id" {
  value = azurerm_user_assigned_identity.pfm_core_ledger_identity.client_id
}
