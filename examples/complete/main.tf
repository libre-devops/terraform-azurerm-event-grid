locals {
  location  = lookup(var.regions, var.loc, "uksouth")
  rg_name   = "rg-${var.short}-${var.loc}-${terraform.workspace}-002"
  kv_name   = "kv-${var.short}-${var.loc}-${terraform.workspace}-002"
  sa_name   = "sa${var.short}${var.loc}${terraform.workspace}evt002"
  evgt_name = "evgt-${var.short}-${var.loc}-${terraform.workspace}-002"
  egst_name = "egst-${var.short}-${var.loc}-${terraform.workspace}-002"
  evgd_name = "evgd-${var.short}-${var.loc}-${terraform.workspace}-002"
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

# The rotation chassis event source: a Key Vault whose secrets carry expiry dates.
# SecretNearExpiry/SecretExpired events flow out through the system topic below. Disposable test
# vault, so purge protection is off.
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

# Delivery and dead-letter target: rotation events land on a storage queue (management-plane
# creation, no data-plane dance); undeliverable events archive into the dead-letter container.
module "storage" {
  source  = "libre-devops/storage-account/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  storage_accounts = {
    (local.sa_name) = {}
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

# Complete call: the full surface. The system topic is the vault's event feed and its
# near-expiry subscription is the rotation chassis: filtered to the two expiry events, delivered
# to the queue with the system topic's managed identity, explicit retries, dead-lettering. The
# custom topic and domain demonstrate the publish surfaces (Entra-only by default) with a
# filtered fan-out subscription.
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
      identity = {}

      inbound_ip_rules = [
        # TEST-NET-3 documentation range: stands in for a publisher's egress CIDR.
        { ip_mask = "203.0.113.0/24" }
      ]
    }
  }

  domains = {
    (local.evgd_name) = {
      domain_topics = ["evgdt-orders", "evgdt-billing"]
    }
  }

  event_subscriptions = {
    # The rotation chassis: near-expiry and expired secrets queue for the rotor to consume.
    # Managed identity delivery is the private-target pattern (the identity needs the Storage
    # Queue Data Message Sender role on the account, assigned below).
    "evgs-secret-rotation" = {
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
    }

    # Filtered fan-out from the custom topic: only high-severity application events reach the
    # queue, with a static delivery property stamped on for the consumer.
    "evgs-high-severity-application-events" = {
      topic = local.evgt_name

      storage_queue_endpoint = {
        storage_account_id = module.storage.ids[local.sa_name]
        queue_name         = azurerm_storage_queue.rotation.name
      }

      subject_filter = {
        subject_begins_with = "application/"
      }

      advanced_filter = {
        string_in           = [{ key = "data.severity", values = ["High", "Critical"] }]
        number_greater_than = [{ key = "data.occurrences", value = 1 }]
      }

      delivery_properties = [
        { header_name = "x-routed-by", type = "Static", value = "evgs-high-severity-application-events" }
      ]

      retry_policy = {
        max_delivery_attempts = 10
        event_time_to_live    = 1440
      }

      storage_blob_dead_letter_destination = {
        storage_account_id          = module.storage.ids[local.sa_name]
        storage_blob_container_name = azurerm_storage_container.deadletter.name
      }
    }
  }
}

# Managed identity delivery: the system topic's identity sends queue messages and writes
# dead-letter blobs. Role assignments live with the consumer, not the module.
resource "azurerm_role_assignment" "system_topic_queue_sender" {
  scope                = module.storage.ids[local.sa_name]
  role_definition_name = "Storage Queue Data Message Sender"
  principal_id         = module.event_grid.system_topic_identities[local.egst_name].principal_id
}

resource "azurerm_role_assignment" "system_topic_deadletter_writer" {
  scope                = module.storage.ids[local.sa_name]
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.event_grid.system_topic_identities[local.egst_name].principal_id
}
