<!--
  Header for the private example README. Edit this file, then run `just docs`
  (or ./Sort-LdoTerraform.ps1 -IncludeExamples) to regenerate the section between the markers.
  The example's main.tf is embedded into the README automatically (see .terraform-docs.yml).
-->
<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="200">
    </picture>
  </a>
</div>

# Private example

The private tier of the rotation chassis: the custom topic, the vault, and both storage
subresources sit behind private endpoints, with their privatelink zones (eventgrid, vaultcore,
queue, blob) linked to the vnet through the Libre DevOps private-dns-zone and private-endpoint
modules. Event Grid delivers near-expiry events by managed identity onto a queue in a storage
account that denies public network access: a resource instance rule scoped to the system topic
does the admitting, so there is no public opening and no service-wide trusted bypass. The
environment comes from the Terraform workspace (`terraform.workspace`), not a variable. Run it
with `just e2e private`, which applies the stack then always destroys it.

[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)

<!-- BEGIN_TF_DOCS -->
## Example configuration

```hcl
locals {
  location  = lookup(var.regions, var.loc, "uksouth")
  rg_name   = "rg-${var.short}-${var.loc}-${terraform.workspace}-003"
  vnet_name = "vnet-${var.short}-${var.loc}-${terraform.workspace}-003"
  kv_name   = "kv-${var.short}-${var.loc}-${terraform.workspace}-003"
  sa_name   = "sa${var.short}${var.loc}${terraform.workspace}evt003"
  evgt_name = "evgt-${var.short}-${var.loc}-${terraform.workspace}-003"
  egst_name = "egst-${var.short}-${var.loc}-${terraform.workspace}-003"

  # Resource instance rule for the storage firewall: the system topic's id is constructed rather
  # than referenced so the storage account (which the Event Grid module's subscriptions need)
  # does not also depend on the Event Grid module. Instance rules accept ids that do not exist
  # yet.
  egst_id = "${module.rg.ids[local.rg_name]}/providers/Microsoft.EventGrid/systemTopics/${local.egst_name}"
}

data "azurerm_client_config" "current" {}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = "1888/67"
  owner           = "platform@example.com"
  deployed_branch = var.deployed_branch
  deployed_repo   = var.deployed_repo
  additional_tags = { Application = "terraform-azurerm-event-grid" }
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

module "network" {
  source  = "libre-devops/network/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  vnet_name     = local.vnet_name
  address_space = ["10.60.0.0/24"]

  subnets = {
    "snet-pep-${local.vnet_name}" = {
      address_prefixes = ["10.60.0.0/27"]
    }
  }
}

# The event source: a Key Vault whose near-expiry events feed the system topic. Event emission
# is service-side, so the vault's network posture does not gate the event flow. Disposable test
# vault, purge protection off.
module "key_vault" {
  source  = "libre-devops/keyvault/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  tenant_id = data.azurerm_client_config.current.tenant_id

  key_vaults = {
    (local.kv_name) = {
      purge_protection_enabled = false
    }
  }
}

# The private delivery target: a storage account that DENIES public network access except for
# the system topic's resource instance rule. Event Grid delivers with the system topic's managed
# identity, so no public opening and no service-wide trusted bypass is needed for delivery.
module "storage" {
  source  = "libre-devops/storage-account/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  storage_accounts = {
    (local.sa_name) = {
      network_rules = {
        default_action = "Deny"
        bypass         = ["AzureServices"]

        private_link_access = [
          { endpoint_resource_id = local.egst_id }
        ]
      }
    }
  }
}

resource "azurerm_storage_queue" "rotation" {
  storage_account_id = module.storage.ids[local.sa_name]
  name               = "secret-rotation"
}

resource "azurerm_storage_container" "deadletter" {
  storage_account_id    = module.storage.ids[local.sa_name]
  name                  = "deadletter"
  container_access_type = "private"
}

# Private publish surface: the custom topic refuses the public internet entirely; publishers
# reach it through the private endpoint below.
module "event_grid" {
  source = "../../"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  system_topics = {
    (local.egst_name) = {
      source_resource_id = module.key_vault.ids[local.kv_name]
      topic_type         = "Microsoft.KeyVault.vaults"

      identity = {}
    }
  }

  topics = {
    (local.evgt_name) = {
      public_network_access_enabled = false

      identity = {}
    }
  }

  event_subscriptions = {
    # The private rotation chassis: near-expiry events delivered by managed identity onto a
    # queue in an account that denies public network access (instance rule + RBAC, no public
    # opening).
    "evgs-secret-rotation-private" = {
      system_topic         = local.egst_name
      included_event_types = ["Microsoft.KeyVault.SecretNearExpiry", "Microsoft.KeyVault.SecretExpired"]

      storage_queue_endpoint = {
        storage_account_id                    = module.storage.ids[local.sa_name]
        queue_name                            = azurerm_storage_queue.rotation.name
        queue_message_time_to_live_in_seconds = 3600
      }

      delivery_identity = {}

      retry_policy = {
        max_delivery_attempts = 10
        event_time_to_live    = 1440
      }

      storage_blob_dead_letter_destination = {
        storage_account_id          = module.storage.ids[local.sa_name]
        storage_blob_container_name = azurerm_storage_container.deadletter.name
      }

      dead_letter_identity = {}

      delivery_identity_role_assignments = [
        { scope = module.storage.ids[local.sa_name], role_definition_name = "Storage Queue Data Message Sender" },
        { scope = module.storage.ids[local.sa_name], role_definition_name = "Storage Blob Data Contributor" },
      ]
    }
  }
}

# The privatelink zones for every service in the stack, all linked to the vnet. Private
# consumers resolve through these; the public endpoints stay up (firewalled) for CI operability.
module "private_dns" {
  source  = "libre-devops/private-dns-zone/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  tags              = module.tags.tags

  private_dns_zones = {
    "privatelink.eventgrid.azure.net"    = {}
    "privatelink.vaultcore.azure.net"    = {}
    "privatelink.queue.core.windows.net" = {}
    "privatelink.blob.core.windows.net"  = {}
  }

  default_vnet_links = {
    "link-${local.vnet_name}" = {
      virtual_network_id = module.network.vnet_id
    }
  }
}

# Private endpoints for every service: the topic's inbound publish path plus the vault and both
# storage subresources, DNS zone groups auto-resolved by subresource name.
module "private_endpoint" {
  source  = "libre-devops/private-endpoint/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  private_dns_zone_ids = {
    topic = module.private_dns.private_dns_zone_ids["privatelink.eventgrid.azure.net"]
    vault = module.private_dns.private_dns_zone_ids["privatelink.vaultcore.azure.net"]
    queue = module.private_dns.private_dns_zone_ids["privatelink.queue.core.windows.net"]
    blob  = module.private_dns.private_dns_zone_ids["privatelink.blob.core.windows.net"]
  }

  private_endpoints = {
    topic = {
      subnet_id           = module.network.subnet_ids["snet-pep-${local.vnet_name}"]
      auto_dns_zone_group = true

      private_service_connection = {
        private_connection_resource_id = module.event_grid.topic_ids[local.evgt_name]
        subresource_names              = ["topic"]
      }
    }

    vault = {
      subnet_id           = module.network.subnet_ids["snet-pep-${local.vnet_name}"]
      auto_dns_zone_group = true

      private_service_connection = {
        private_connection_resource_id = module.key_vault.ids[local.kv_name]
        subresource_names              = ["vault"]
      }
    }

    storage_queue = {
      subnet_id           = module.network.subnet_ids["snet-pep-${local.vnet_name}"]
      auto_dns_zone_group = true

      private_service_connection = {
        private_connection_resource_id = module.storage.ids[local.sa_name]
        subresource_names              = ["queue"]
      }
    }

    storage_blob = {
      subnet_id           = module.network.subnet_ids["snet-pep-${local.vnet_name}"]
      auto_dns_zone_group = true

      private_service_connection = {
        private_connection_resource_id = module.storage.ids[local.sa_name]
        subresource_names              = ["blob"]
      }
    }
  }
}
```

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0, < 2.0.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.0.0, < 5.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 4.0.0, < 5.0.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_event_grid"></a> [event\_grid](#module\_event\_grid) | ../../ | n/a |
| <a name="module_key_vault"></a> [key\_vault](#module\_key\_vault) | libre-devops/keyvault/azurerm | ~> 4.0 |
| <a name="module_network"></a> [network](#module\_network) | libre-devops/network/azurerm | ~> 4.0 |
| <a name="module_private_dns"></a> [private\_dns](#module\_private\_dns) | libre-devops/private-dns-zone/azurerm | ~> 4.0 |
| <a name="module_private_endpoint"></a> [private\_endpoint](#module\_private\_endpoint) | libre-devops/private-endpoint/azurerm | ~> 4.0 |
| <a name="module_rg"></a> [rg](#module\_rg) | libre-devops/rg/azurerm | ~> 4.0 |
| <a name="module_storage"></a> [storage](#module\_storage) | libre-devops/storage-account/azurerm | ~> 4.0 |
| <a name="module_tags"></a> [tags](#module\_tags) | libre-devops/tags/azurerm | ~> 4.0 |

## Resources

| Name | Type |
|------|------|
| [azurerm_storage_container.deadletter](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container) | resource |
| [azurerm_storage_queue.rotation](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_queue) | resource |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_deployed_branch"></a> [deployed\_branch](#input\_deployed\_branch) | Git branch the deployment came from. Auto-filled in CI from TF\_VAR\_deployed\_branch. | `string` | `""` | no |
| <a name="input_deployed_repo"></a> [deployed\_repo](#input\_deployed\_repo) | Repository URL the deployment came from. Auto-filled in CI from TF\_VAR\_deployed\_repo. | `string` | `""` | no |
| <a name="input_loc"></a> [loc](#input\_loc) | Outfix: short Azure region code used in resource names (for example uks). | `string` | `"uks"` | no |
| <a name="input_regions"></a> [regions](#input\_regions) | Map of short region codes to Azure region slugs. | `map(string)` | <pre>{<br/>  "eus": "eastus",<br/>  "euw": "westeurope",<br/>  "uks": "uksouth",<br/>  "ukw": "ukwest"<br/>}</pre> | no |
| <a name="input_short"></a> [short](#input\_short) | Infix: short product code used in resource names. | `string` | `"ldo"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
