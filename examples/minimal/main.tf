locals {
  location  = lookup(var.regions, var.loc, "uksouth")
  rg_name   = "rg-${var.short}-${var.loc}-${terraform.workspace}-001"
  sa_name   = "sa${var.short}${var.loc}${terraform.workspace}evt001"
  evgt_name = "evgt-${var.short}-${var.loc}-${terraform.workspace}-001"
}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = "1888/67"
  owner           = "platform@example.com"
  deployed_branch = var.deployed_branch
  deployed_repo   = var.deployed_repo
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

# Delivery target: events land on a storage queue (created management-plane, no data-plane dance).
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

resource "azurerm_storage_queue" "events" {
  storage_account_id = module.storage.ids[local.sa_name]
  name               = "events"
}

# Minimal call: one Entra-only custom topic delivering to a storage queue. The dead-letter check
# will point out the missing destination; the complete example shows the full posture.
module "event_grid" {
  source = "../../"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  topics = {
    (local.evgt_name) = {}
  }

  event_subscriptions = {
    "evgs-application-events" = {
      topic = local.evgt_name

      storage_queue_endpoint = {
        storage_account_id = module.storage.ids[local.sa_name]
        queue_name         = azurerm_storage_queue.events.name
      }
    }
  }
}
