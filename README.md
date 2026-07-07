<!--
  Keep the title and badges OUTSIDE the centered <div>: the Terraform Registry's markdown renderer
  does not parse markdown inside an HTML block, so a # heading or [![badge]] in the div renders as
  literal text on the registry. Only the logo (HTML) goes in the div.
-->
<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="300">
    </picture>
  </a>
</div>

# Terraform Azure Event Grid

Azure Event Grid custom topics, system topics, domains, and event subscriptions, with one typed
subscription map serving every source, Entra ID first.

[![CI](https://github.com/libre-devops/terraform-azurerm-event-grid/actions/workflows/ci.yml/badge.svg)](https://github.com/libre-devops/terraform-azurerm-event-grid/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/libre-devops/terraform-azurerm-event-grid?sort=semver&label=release)](https://github.com/libre-devops/terraform-azurerm-event-grid/releases/latest)
[![Terraform Registry](https://img.shields.io/badge/registry-libre--devops-7B42BC?logo=terraform&logoColor=white)](https://registry.terraform.io/namespaces/libre-devops)
[![License](https://img.shields.io/github/license/libre-devops/terraform-azurerm-event-grid)](./LICENSE)

---

## Overview

Event Grid is the only door Azure resource events come out of, and its Terraform surface splits
awkwardly across two subscription resources and three source kinds. The module folds it into
four maps with the awkwardness handled:

- **One subscription shape for every source**: each entry in `event_subscriptions` names exactly
  one of `topic`, `system_topic`, or `domain` (from this call) or any subscribable ARM id via
  `scope` (a subscription, resource group, storage account...). System topic subscriptions route
  to their dedicated resource, everything else resolves to a scope on the generic one, and the
  cross-references are validated at plan time so a typo cannot deploy.
- **Exactly one endpoint per subscription**, validated: webhook (with optional AAD auth), Azure
  Function, storage queue, event hub, service bus queue or topic, or hybrid connection.
  `delivery_identity` enables managed identity delivery (the pattern for firewalled targets:
  Event Grid authenticates instead of relying on network reachability).
- **Failure handling is explicit**: typed `retry_policy`, storage blob dead-lettering with its
  own identity, and a `check` that surfaces subscriptions without a dead-letter destination
  (undeliverable events vanish once retries exhaust).
- **The full filter surface, typed**: subject filters plus all nineteen advanced filter
  operators as typed lists, and delivery properties validated as Static-with-value or
  Dynamic-with-source.
- **Entra ID first**: custom topics and domains default `local_auth_enabled = false`, so access
  keys are off and publishers use the EventGrid Data Sender role.

The resource group is passed by id and parsed. Deferred by design: Event Grid namespaces (the
MQTT/pull tier) and partner topics are separate surfaces for separate modules if they earn one.

## Usage

```hcl
module "event_grid" {
  source  = "libre-devops/event-grid/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids["rg-ldo-uks-prd-001"]
  location          = "uksouth"
  tags              = module.tags.tags

  system_topics = {
    "egst-ldo-uks-prd-001" = {
      source_resource_id = module.key_vault.ids["kv-ldo-uks-prd-001"]
      topic_type         = "Microsoft.KeyVault.vaults"
      identity           = {}
    }
  }

  event_subscriptions = {
    "evgs-secret-rotation" = {
      system_topic         = "egst-ldo-uks-prd-001"
      included_event_types = ["Microsoft.KeyVault.SecretNearExpiry", "Microsoft.KeyVault.SecretExpired"]

      storage_queue_endpoint = {
        storage_account_id = module.storage.ids["saldouksprd001"]
        queue_name         = "secret-rotation"
      }

      delivery_identity = {}

      retry_policy = {
        max_delivery_attempts = 10
        event_time_to_live    = 1440
      }

      storage_blob_dead_letter_destination = {
        storage_account_id          = module.storage.ids["saldouksprd001"]
        storage_blob_container_name = "deadletter"
      }
    }
  }
}
```

The `examples/minimal` stack is one custom topic delivering to a storage queue;
`examples/complete` is the credential-rotation chassis: a Key Vault system topic whose
near-expiry events queue for a rotor with managed identity delivery, explicit retries, and
dead-lettering, alongside a filtered custom-topic fan-out and a domain with domain topics.
`examples/private` is the private tier: private endpoints (with their privatelink DNS zones,
auto-resolved by subresource) on the custom topic, the vault, and both storage subresources;
the topic disables public network access outright, while the vault and storage keep firewalled
public endpoints alongside their private ones (the CI-operable both-worlds posture), and
delivery lands on the deny-by-default storage account via the system topic's resource instance
rule plus managed identity.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0, < 2.0.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.0.0, < 5.0.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.9.0, < 1.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 4.0.0, < 5.0.0 |
| <a name="provider_time"></a> [time](#provider\_time) | >= 0.9.0, < 1.0.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_eventgrid_domain.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventgrid_domain) | resource |
| [azurerm_eventgrid_domain_topic.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventgrid_domain_topic) | resource |
| [azurerm_eventgrid_event_subscription.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventgrid_event_subscription) | resource |
| [azurerm_eventgrid_system_topic.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventgrid_system_topic) | resource |
| [azurerm_eventgrid_system_topic_event_subscription.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventgrid_system_topic_event_subscription) | resource |
| [azurerm_eventgrid_topic.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/eventgrid_topic) | resource |
| [azurerm_role_assignment.delivery](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [time_sleep.rbac_propagation](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_domains"></a> [domains](#input\_domains) | Event Grid domains keyed by name: multi-tenant ingestion endpoints whose domain topics are<br/>lightweight children (domain\_topics is a set of names). Subscriptions attach through<br/>event\_subscriptions with domain = "<name>". Same posture as topics: local\_auth\_enabled<br/>defaults to false. | <pre>map(object({<br/>    tags = optional(map(string))<br/><br/>    input_schema                  = optional(string, "EventGridSchema")<br/>    local_auth_enabled            = optional(bool, false)<br/>    public_network_access_enabled = optional(bool, true)<br/><br/>    auto_create_topic_with_first_subscription = optional(bool, true)<br/>    auto_delete_topic_with_last_subscription  = optional(bool, true)<br/><br/>    inbound_ip_rules = optional(list(object({<br/>      ip_mask = string<br/>      action  = optional(string, "Allow")<br/>    })), [])<br/><br/>    identity = optional(object({<br/>      type         = optional(string, "SystemAssigned")<br/>      identity_ids = optional(set(string))<br/>    }))<br/><br/>    domain_topics = optional(set(string), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_event_subscriptions"></a> [event\_subscriptions](#input\_event\_subscriptions) | Event subscriptions keyed by name. Each targets exactly one source: a custom topic from this<br/>module (topic = "<name>"), a system topic from this module (system\_topic = "<name>"), a<br/>domain from this module (domain = "<name>"), or any subscribable ARM id (scope = "<id>",<br/>for example a subscription, resource group, or storage account).<br/><br/>Each delivers to exactly one endpoint: webhook\_endpoint, azure\_function\_endpoint,<br/>storage\_queue\_endpoint, or one of the *\_endpoint\_id strings (event hub, service bus queue<br/>or topic, hybrid connection). delivery\_identity lets Event Grid deliver with the source's<br/>managed identity (the private-target pattern); storage\_blob\_dead\_letter\_destination and<br/>retry\_policy make failure handling explicit. | <pre>map(object({<br/>    scope        = optional(string)<br/>    topic        = optional(string)<br/>    system_topic = optional(string)<br/>    domain       = optional(string)<br/><br/>    event_delivery_schema = optional(string, "EventGridSchema")<br/>    included_event_types  = optional(list(string))<br/>    labels                = optional(list(string))<br/>    expiration_time_utc   = optional(string)<br/><br/>    advanced_filtering_on_arrays_enabled = optional(bool, false)<br/><br/>    subject_filter = optional(object({<br/>      subject_begins_with = optional(string)<br/>      subject_ends_with   = optional(string)<br/>      case_sensitive      = optional(bool)<br/>    }))<br/><br/>    advanced_filter = optional(object({<br/>      bool_equals                   = optional(list(object({ key = string, value = bool })), [])<br/>      is_not_null                   = optional(list(object({ key = string })), [])<br/>      is_null_or_undefined          = optional(list(object({ key = string })), [])<br/>      number_greater_than           = optional(list(object({ key = string, value = number })), [])<br/>      number_greater_than_or_equals = optional(list(object({ key = string, value = number })), [])<br/>      number_less_than              = optional(list(object({ key = string, value = number })), [])<br/>      number_less_than_or_equals    = optional(list(object({ key = string, value = number })), [])<br/>      number_in                     = optional(list(object({ key = string, values = list(number) })), [])<br/>      number_not_in                 = optional(list(object({ key = string, values = list(number) })), [])<br/>      number_in_range               = optional(list(object({ key = string, values = list(list(number)) })), [])<br/>      number_not_in_range           = optional(list(object({ key = string, values = list(list(number)) })), [])<br/>      string_begins_with            = optional(list(object({ key = string, values = list(string) })), [])<br/>      string_not_begins_with        = optional(list(object({ key = string, values = list(string) })), [])<br/>      string_ends_with              = optional(list(object({ key = string, values = list(string) })), [])<br/>      string_not_ends_with          = optional(list(object({ key = string, values = list(string) })), [])<br/>      string_contains               = optional(list(object({ key = string, values = list(string) })), [])<br/>      string_not_contains           = optional(list(object({ key = string, values = list(string) })), [])<br/>      string_in                     = optional(list(object({ key = string, values = list(string) })), [])<br/>      string_not_in                 = optional(list(object({ key = string, values = list(string) })), [])<br/>    }))<br/><br/>    webhook_endpoint = optional(object({<br/>      url                               = string<br/>      max_events_per_batch              = optional(number)<br/>      preferred_batch_size_in_kilobytes = optional(number)<br/>      active_directory_tenant_id        = optional(string)<br/>      active_directory_app_id_or_uri    = optional(string)<br/>    }))<br/><br/>    azure_function_endpoint = optional(object({<br/>      function_id                       = string<br/>      max_events_per_batch              = optional(number)<br/>      preferred_batch_size_in_kilobytes = optional(number)<br/>    }))<br/><br/>    storage_queue_endpoint = optional(object({<br/>      storage_account_id                    = string<br/>      queue_name                            = string<br/>      queue_message_time_to_live_in_seconds = optional(number)<br/>    }))<br/><br/>    eventhub_endpoint_id          = optional(string)<br/>    service_bus_queue_endpoint_id = optional(string)<br/>    service_bus_topic_endpoint_id = optional(string)<br/>    hybrid_connection_endpoint_id = optional(string)<br/><br/>    delivery_identity = optional(object({<br/>      type                   = optional(string, "SystemAssigned")<br/>      user_assigned_identity = optional(string)<br/>    }))<br/><br/>    # Role assignments the SOURCE's managed identity needs on the destination, created by the<br/>    # module BETWEEN the source and the subscription: Event Grid validates delivery permission<br/>    # at subscription-create time (proven live), so consumer-side assignments arrive too late.<br/>    delivery_identity_role_assignments = optional(list(object({<br/>      scope                = string<br/>      role_definition_name = string<br/>    })), [])<br/><br/>    delivery_properties = optional(list(object({<br/>      header_name  = string<br/>      type         = string<br/>      value        = optional(string)<br/>      source_field = optional(string)<br/>      secret       = optional(bool)<br/>    })), [])<br/><br/>    retry_policy = optional(object({<br/>      max_delivery_attempts = number<br/>      event_time_to_live    = number<br/>    }))<br/><br/>    storage_blob_dead_letter_destination = optional(object({<br/>      storage_account_id          = string<br/>      storage_blob_container_name = string<br/>    }))<br/><br/>    dead_letter_identity = optional(object({<br/>      type                   = optional(string, "SystemAssigned")<br/>      user_assigned_identity = optional(string)<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_location"></a> [location](#input\_location) | Azure region for the topics and domains (system topics follow their source's region, global for subscription and resource group sources). | `string` | n/a | yes |
| <a name="input_resource_group_id"></a> [resource\_group\_id](#input\_resource\_group\_id) | Resource id of the resource group the resources are created in. The resource group name and subscription are parsed from this id. | `string` | n/a | yes |
| <a name="input_system_topics"></a> [system\_topics](#input\_system\_topics) | Event Grid system topics keyed by name: the event feed of an existing Azure resource<br/>(Key Vault, storage account, resource group, subscription). source\_resource\_id is the<br/>emitting resource; topic\_type is its system topic type (for example Microsoft.KeyVault.vaults<br/>or Microsoft.Storage.StorageAccounts; list them with az eventgrid topic-type list).<br/>Subscriptions attach through event\_subscriptions with system\_topic = "<name>". | <pre>map(object({<br/>    source_resource_id = string<br/>    topic_type         = string<br/>    tags               = optional(map(string))<br/><br/>    identity = optional(object({<br/>      type         = optional(string, "SystemAssigned")<br/>      identity_ids = optional(set(string))<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the topics, system topics, and domains (unless one sets its own). | `map(string)` | `{}` | no |
| <a name="input_topics"></a> [topics](#input\_topics) | Event Grid custom topics keyed by name: endpoints your own applications publish to.<br/>local\_auth\_enabled defaults to FALSE, so the access keys are off and publishers authenticate<br/>with Entra ID (EventGrid Data Sender role). Subscriptions attach through event\_subscriptions<br/>with topic = "<name>". input\_mapping applies only to CustomEventSchema topics. | <pre>map(object({<br/>    tags = optional(map(string))<br/><br/>    input_schema                  = optional(string, "EventGridSchema")<br/>    local_auth_enabled            = optional(bool, false)<br/>    public_network_access_enabled = optional(bool, true)<br/><br/>    inbound_ip_rules = optional(list(object({<br/>      ip_mask = string<br/>      action  = optional(string, "Allow")<br/>    })), [])<br/><br/>    identity = optional(object({<br/>      type         = optional(string, "SystemAssigned")<br/>      identity_ids = optional(set(string))<br/>    }))<br/><br/>    input_mapping_fields = optional(object({<br/>      id           = optional(string)<br/>      topic        = optional(string)<br/>      event_type   = optional(string)<br/>      event_time   = optional(string)<br/>      data_version = optional(string)<br/>      subject      = optional(string)<br/>    }))<br/><br/>    input_mapping_default_values = optional(object({<br/>      event_type   = optional(string)<br/>      data_version = optional(string)<br/>      subject      = optional(string)<br/>    }))<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_delivery_role_assignment_ids"></a> [delivery\_role\_assignment\_ids](#output\_delivery\_role\_assignment\_ids) | Map of subscription/index composite key to the delivery role assignment id the module created for it. |
| <a name="output_domain_endpoints"></a> [domain\_endpoints](#output\_domain\_endpoints) | Map of domain name to its publish endpoint. |
| <a name="output_domain_identities"></a> [domain\_identities](#output\_domain\_identities) | Map of domain name to its identity { principal\_id, tenant\_id } when one is set. |
| <a name="output_domain_ids"></a> [domain\_ids](#output\_domain\_ids) | Map of domain name to its resource id. |
| <a name="output_domain_topic_ids"></a> [domain\_topic\_ids](#output\_domain\_topic\_ids) | Map of domain/topic composite key to domain topic id. |
| <a name="output_event_subscription_ids"></a> [event\_subscription\_ids](#output\_event\_subscription\_ids) | Map of subscription name to its resource id (both scoped and system topic subscriptions). |
| <a name="output_resource_group_name"></a> [resource\_group\_name](#output\_resource\_group\_name) | Resource group name parsed from resource\_group\_id. |
| <a name="output_subscription_id"></a> [subscription\_id](#output\_subscription\_id) | Subscription id parsed from resource\_group\_id. |
| <a name="output_system_topic_identities"></a> [system\_topic\_identities](#output\_system\_topic\_identities) | Map of system topic name to its identity { principal\_id, tenant\_id } when one is set (for delivery\_identity role assignments). |
| <a name="output_system_topic_ids"></a> [system\_topic\_ids](#output\_system\_topic\_ids) | Map of system topic name to its resource id. |
| <a name="output_system_topic_ids_zipmap"></a> [system\_topic\_ids\_zipmap](#output\_system\_topic\_ids\_zipmap) | Map of system topic name to a { name, id } object, for passing where both are needed together. |
| <a name="output_system_topic_metric_arm_resource_ids"></a> [system\_topic\_metric\_arm\_resource\_ids](#output\_system\_topic\_metric\_arm\_resource\_ids) | Map of system topic name to its metric ARM resource id. |
| <a name="output_tags"></a> [tags](#output\_tags) | The base tags applied to the topics, system topics, and domains. |
| <a name="output_topic_endpoints"></a> [topic\_endpoints](#output\_topic\_endpoints) | Map of custom topic name to its publish endpoint. |
| <a name="output_topic_identities"></a> [topic\_identities](#output\_topic\_identities) | Map of custom topic name to its identity { principal\_id, tenant\_id } when one is set. |
| <a name="output_topic_ids"></a> [topic\_ids](#output\_topic\_ids) | Map of custom topic name to its resource id. |
| <a name="output_topic_ids_zipmap"></a> [topic\_ids\_zipmap](#output\_topic\_ids\_zipmap) | Map of custom topic name to a { name, id } object, for passing where both are needed together. |
<!-- END_TF_DOCS -->
