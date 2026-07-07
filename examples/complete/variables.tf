# Forwarded into the tags module for the DeployedBranch / DeployedRepo tags. The terraform-azure
# action fills these in CI via TF_VAR_deployed_branch / TF_VAR_deployed_repo; empty when run locally.
variable "deployed_branch" {
  description = "Git branch the deployment came from. Auto-filled in CI from TF_VAR_deployed_branch."
  type        = string
  default     = ""
}

variable "deployed_repo" {
  description = "Repository URL the deployment came from. Auto-filled in CI from TF_VAR_deployed_repo."
  type        = string
  default     = ""
}

variable "loc" {
  description = "Outfix: short Azure region code used in resource names (for example uks)."
  type        = string
  default     = "uks"
}

variable "regions" {
  description = "Map of short region codes to Azure region slugs."
  type        = map(string)
  default = {
    uks = "uksouth"
    ukw = "ukwest"
    eus = "eastus"
    euw = "westeurope"
  }
}

variable "rotation_validity_days" {
  description = "Validity stamped on each rotated secret version. Near-expiry fires 30 days before expiry, so the rotation cadence is this minus 30."
  type        = number
  default     = 60
}

variable "short" {
  description = "Infix: short product code used in resource names."
  type        = string
  default     = "ldo"
}

variable "storage_api_version" {
  description = "ARM API version for the storage regenerateKey call the rotor makes."
  type        = string
  default     = "2023-01-01"
}

variable "vault_api_version" {
  description = "Key Vault data-plane API version for the rotor's secret reads and writes."
  type        = string
  default     = "7.4"
}
