<!--
  Header for the complete example README. Edit this file, then run `just docs`
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

# Complete example

Exercises the fuller surface of this module, built around the secret-rotation exemplar: a Key
Vault system topic delivers near-expiry events over an Event Grid webhook into a Consumption
Logic App workflow that regenerates the inactive storage key and writes the rotated secret back
as a new version (see `templates/rotation-handler.json.tftpl`). Around it sit a
public-network-disabled custom topic, a domain with its domain topics, managed-identity queue
delivery with blob dead-lettering and in-module delivery role assignments, and the TLS 1.2 shim
on topics and domains. The rotor vault is deliberately network-open and RBAC-gated (see the
security scan exceptions table in the repo README); the private example shows the
deny-by-default posture. The environment comes from the Terraform workspace
(`terraform.workspace`), not a variable. Run it with `just e2e complete`, which applies the
stack then always destroys it.

[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)

<!-- BEGIN_TF_DOCS -->
## Example configuration

```hcl
locals {
  location   = lookup(var.regions, var.loc, "uksouth")
  rg_name    = "rg-${var.short}-${var.loc}-${terraform.workspace}-002"
  kv_name    = "kv-${var.short}-${var.loc}-${terraform.workspace}-002"
  sa_name    = "sa${var.short}${var.loc}${terraform.workspace}evt002"
  evgt_name  = "evgt-${var.short}-${var.loc}-${terraform.workspace}-002"
  egst_name  = "egst-${var.short}-${var.loc}-${terraform.workspace}-002"
  evgd_name  = "evgd-${var.short}-${var.loc}-${terraform.workspace}-002"
  logic_name = "logic-${var.short}-${var.loc}-${terraform.workspace}-002"
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

      # PUBLIC TIER POSTURE: the Consumption rotor writes the new secret version from Logic
      # Apps' shared outbound IPs, which cannot sanely be allow-listed (the standard bans
      # allow-listing the regional ranges), so this vault stays network-open and RBAC-gated.
      # Locked-down vaults belong to the private tier (Standard logic app over a private
      # endpoint, see the standards doc).
      network_acls = {
        default_action = "Allow"
      }
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


# ------------------------------------------------------------------------------------------------
# The rotor: a Consumption workflow receiving the near-expiry event straight from Event Grid.
# It answers the subscription validation handshake in-workflow, accepts real events with 202
# inside Event Grid's 30 second webhook window, reads the rotation contract from the secret's
# tags, regenerates the INACTIVE storage key, and stores it as the new secret version with a
# fresh expiry. Key-touching actions secure their inputs and outputs so run history never shows
# key material.
# ------------------------------------------------------------------------------------------------

module "logic_app_workflow" {
  source  = "libre-devops/logic-app-workflow/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  workflows = {
    (local.logic_name) = {
      title = "Event Grid - Rotate the inactive storage key when a Key Vault secret nears expiry"

      parameters = {
        rotation_validity_days = {
          type        = "Int"
          value       = tostring(var.rotation_validity_days)
          description = "Validity stamped on each new secret version; near-expiry fires 30 days before it, so the cadence is this minus 30."
        }
        storage_api_version = {
          type        = "String"
          value       = var.storage_api_version
          description = "ARM API version for the regenerateKey call."
        }
        vault_api_version = {
          type        = "String"
          value       = var.vault_api_version
          description = "Key Vault data-plane API version for secret reads and writes."
        }
      }
    }
  }
}

resource "azurerm_logic_app_trigger_http_request" "rotation_events" {
  name         = "When_Event_Grid_delivers_a_Key_Vault_event"
  logic_app_id = module.logic_app_workflow.ids[local.logic_name]

  schema = jsonencode({
    type  = "array"
    items = { type = "object" }
  })

  method = "POST"
}

resource "azurerm_logic_app_action_custom" "rotation_handler" {
  name         = "Condition_-_Is_this_the_subscription_validation_handshake"
  logic_app_id = module.logic_app_workflow.ids[local.logic_name]

  body = templatefile("${path.module}/templates/rotation-handler.json.tftpl", {
    workflow_name = local.logic_name
  })

  depends_on = [azurerm_logic_app_trigger_http_request.rotation_events]
}

# Runtime permissions: regenerate keys on the storage account, write secret versions to the
# vault. Neither gates the Event Grid handshake, only rotation runs.
resource "azurerm_role_assignment" "rotor_key_operator" {
  scope                = module.storage.ids[local.sa_name]
  role_definition_name = "Storage Account Key Operator Service Role"
  principal_id         = module.logic_app_workflow.identities[local.logic_name].principal_id
}

resource "azurerm_role_assignment" "rotor_secrets_officer" {
  scope                = module.key_vault.ids[local.kv_name]
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = module.logic_app_workflow.identities[local.logic_name].principal_id
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
    # The rotor path: near-expiry and expired secrets go straight to the workflow's HTTP
    # trigger. Event Grid validates the endpoint at subscription-create time by calling the
    # handshake, so the workflow content must exist first (the module-level depends_on below).
    "evgs-secret-rotation" = {
      system_topic         = local.egst_name
      included_event_types = ["Microsoft.KeyVault.SecretNearExpiry", "Microsoft.KeyVault.SecretExpired"]

      webhook_endpoint = {
        url = azurerm_logic_app_trigger_http_request.rotation_events.callback_url
      }

      retry_policy = {
        max_delivery_attempts = 10
        event_time_to_live    = 1440
      }

      storage_blob_dead_letter_destination = {
        storage_account_id          = module.storage.ids[local.sa_name]
        storage_blob_container_name = azurerm_storage_container.deadletter.name
      }

      # Dead-lettering here rides the Blob Contributor grant on the audit subscription below:
      # both subscriptions share this system topic's identity, and Azure refuses a duplicate
      # (principal, role, scope) role assignment, so a shared source gets each grant exactly once.
      dead_letter_identity = {}
    }

    # The audit trail: the same events also land on the queue with managed identity delivery,
    # the private-target pattern the private example locks down fully.
    "evgs-rotation-audit-trail" = {
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

      # The module creates these between the system topic and the subscription: Event Grid
      # validates delivery permission at subscription-create time, so consumer-side role
      # assignments arrive too late (proven live).
      delivery_identity_role_assignments = [
        { scope = module.storage.ids[local.sa_name], role_definition_name = "Storage Queue Data Message Sender" },
        { scope = module.storage.ids[local.sa_name], role_definition_name = "Storage Blob Data Contributor" },
      ]
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

  # Event Grid executes the rotor's handshake when creating the webhook subscription, so the
  # workflow's content (trigger AND handler action) must be deployed first.
  depends_on = [azurerm_logic_app_action_custom.rotation_handler]
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
| <a name="module_logic_app_workflow"></a> [logic\_app\_workflow](#module\_logic\_app\_workflow) | libre-devops/logic-app-workflow/azurerm | ~> 4.0 |
| <a name="module_rg"></a> [rg](#module\_rg) | libre-devops/rg/azurerm | ~> 4.0 |
| <a name="module_storage"></a> [storage](#module\_storage) | libre-devops/storage-account/azurerm | ~> 4.0 |
| <a name="module_tags"></a> [tags](#module\_tags) | libre-devops/tags/azurerm | ~> 4.0 |

## Resources

| Name | Type |
|------|------|
| [azurerm_logic_app_action_custom.rotation_handler](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/logic_app_action_custom) | resource |
| [azurerm_logic_app_trigger_http_request.rotation_events](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/logic_app_trigger_http_request) | resource |
| [azurerm_role_assignment.rotor_key_operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.rotor_secrets_officer](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
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
| <a name="input_rotation_validity_days"></a> [rotation\_validity\_days](#input\_rotation\_validity\_days) | Validity stamped on each rotated secret version. Near-expiry fires 30 days before expiry, so the rotation cadence is this minus 30. | `number` | `60` | no |
| <a name="input_short"></a> [short](#input\_short) | Infix: short product code used in resource names. | `string` | `"ldo"` | no |
| <a name="input_storage_api_version"></a> [storage\_api\_version](#input\_storage\_api\_version) | ARM API version for the storage regenerateKey call the rotor makes. | `string` | `"2023-01-01"` | no |
| <a name="input_vault_api_version"></a> [vault\_api\_version](#input\_vault\_api\_version) | Key Vault data-plane API version for the rotor's secret reads and writes. | `string` | `"7.4"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
