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

# Inbound privacy for the custom topic: private DNS zone, VNet link, and the private endpoint.
resource "azurerm_private_dns_zone" "eventgrid" {
  resource_group_name = local.rg_name
  tags                = module.tags.tags

  name = "privatelink.eventgrid.azure.net"

  # resource_group_name is a plain string, so the graph edge to the rg must be explicit.
  depends_on = [module.rg]
}

resource "azurerm_private_dns_zone_virtual_network_link" "eventgrid" {
  resource_group_name = local.rg_name
  tags                = module.tags.tags

  name                  = "link-${local.vnet_name}"
  private_dns_zone_name = azurerm_private_dns_zone.eventgrid.name
  virtual_network_id    = module.network.vnet_id
}

module "private_endpoint" {
  source  = "libre-devops/private-endpoint/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  private_endpoints = {
    topic = {
      subnet_id = module.network.subnet_ids["snet-pep-${local.vnet_name}"]

      private_service_connection = {
        private_connection_resource_id = module.event_grid.topic_ids[local.evgt_name]
        subresource_names              = ["topic"]
      }

      private_dns_zone_group = {
        private_dns_zone_ids = [azurerm_private_dns_zone.eventgrid.id]
      }
    }
  }
}
