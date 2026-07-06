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
`examples/private` is the private tier: a custom topic with public network access disabled
behind a private endpoint (with its privatelink DNS zone), and delivery onto a storage account
that denies public access via the system topic's resource instance rule plus managed identity,
no public opening anywhere in the delivery path.
