# Plan-time tests for the module. The provider is mocked, so no credentials, no features block,
# and no cloud calls are needed:
#   terraform init -backend=false && terraform test

mock_provider "azurerm" {}

variables {
  resource_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01"
  location          = "uksouth"
  tags              = { Environment = "tst" }

  topics = {
    "evgt-ldo-uks-tst-01" = {
      identity = {}

      inbound_ip_rules = [{ ip_mask = "203.0.113.0/24" }]
    }
  }

  system_topics = {
    "egst-ldo-uks-tst-01" = {
      source_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01/providers/Microsoft.KeyVault/vaults/kv-ldo-uks-tst-01"
      topic_type         = "Microsoft.KeyVault.vaults"
      identity           = {}
    }
  }

  domains = {
    "evgd-ldo-uks-tst-01" = {
      domain_topics = ["evgdt-orders", "evgdt-billing"]
    }
  }

  event_subscriptions = {
    "evgs-secret-rotation" = {
      system_topic         = "egst-ldo-uks-tst-01"
      included_event_types = ["Microsoft.KeyVault.SecretNearExpiry", "Microsoft.KeyVault.SecretExpired"]

      webhook_endpoint = {
        url = "https://example.com/api/rotate?code=x"
      }

      retry_policy = {
        max_delivery_attempts = 10
        event_time_to_live    = 1440
      }

      storage_blob_dead_letter_destination = {
        storage_account_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01/providers/Microsoft.Storage/storageAccounts/saldoukststdeadletter"
        storage_blob_container_name = "deadletter"
      }
    }

    "evgs-topic-fanout" = {
      topic = "evgt-ldo-uks-tst-01"

      service_bus_queue_endpoint_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01/providers/Microsoft.ServiceBus/namespaces/sb-ldo-uks-tst-01/queues/sbq-events"

      delivery_identity = {}

      advanced_filter = {
        string_in           = [{ key = "data.severity", values = ["High", "Critical"] }]
        number_greater_than = [{ key = "data.count", value = 5 }]
      }

      storage_blob_dead_letter_destination = {
        storage_account_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01/providers/Microsoft.Storage/storageAccounts/saldoukststdeadletter"
        storage_blob_container_name = "deadletter"
      }
    }

    "evgs-rg-audit" = {
      scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01"

      storage_queue_endpoint = {
        storage_account_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01/providers/Microsoft.Storage/storageAccounts/saldoukststdeadletter"
        queue_name         = "audit"
      }

      subject_filter = {
        subject_begins_with = "/subscriptions/"
      }

      storage_blob_dead_letter_destination = {
        storage_account_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01/providers/Microsoft.Storage/storageAccounts/saldoukststdeadletter"
        storage_blob_container_name = "deadletter"
      }
    }
  }
}

# Defaults: Entra-only topics (local auth off), EventGridSchema both ways, public network on.
run "sensible_defaults" {
  command = plan

  assert {
    condition     = azurerm_eventgrid_topic.this["evgt-ldo-uks-tst-01"].local_auth_enabled == false
    error_message = "Custom topics should default to local auth off: Entra ID is the posture."
  }

  assert {
    condition     = azurerm_eventgrid_topic.this["evgt-ldo-uks-tst-01"].input_schema == "EventGridSchema"
    error_message = "Topics should default to the EventGridSchema input schema."
  }

  assert {
    condition     = azurerm_eventgrid_system_topic.this["egst-ldo-uks-tst-01"].topic_type == "Microsoft.KeyVault.vaults"
    error_message = "System topics should carry their source topic type."
  }

  assert {
    condition     = azurerm_eventgrid_topic.this["evgt-ldo-uks-tst-01"].resource_group_name == "rg-ldo-uks-tst-01"
    error_message = "The resource group name should be parsed from resource_group_id."
  }
}

# Source routing: system topic subscriptions use the dedicated resource, module topics and raw
# scopes use the generic resource with the right scope.
run "subscription_sources_route" {
  command = plan

  assert {
    condition     = azurerm_eventgrid_system_topic_event_subscription.this["evgs-secret-rotation"].system_topic == "egst-ldo-uks-tst-01"
    error_message = "System topic subscriptions should route to the dedicated resource."
  }

  assert {
    condition     = length([for k, v in azurerm_eventgrid_event_subscription.this : k]) == 2
    error_message = "Topic and scope subscriptions should route to the generic resource."
  }

  assert {
    condition     = azurerm_eventgrid_event_subscription.this["evgs-rg-audit"].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01"
    error_message = "Raw scope subscriptions should pass their scope through."
  }

  assert {
    condition     = contains(azurerm_eventgrid_system_topic_event_subscription.this["evgs-secret-rotation"].included_event_types, "Microsoft.KeyVault.SecretNearExpiry")
    error_message = "Included event types should pass through."
  }
}

# Rendering: filters, retry, dead letter, delivery identity, domain topics.
run "nested_blocks_render" {
  command = plan

  assert {
    condition     = tolist(azurerm_eventgrid_event_subscription.this["evgs-topic-fanout"].advanced_filter)[0].string_in[0].values[0] == "High"
    error_message = "Advanced string_in filters should render."
  }

  assert {
    condition     = tolist(azurerm_eventgrid_event_subscription.this["evgs-topic-fanout"].advanced_filter)[0].number_greater_than[0].value == 5
    error_message = "Advanced number filters should render."
  }

  assert {
    condition     = tolist(azurerm_eventgrid_event_subscription.this["evgs-topic-fanout"].delivery_identity)[0].type == "SystemAssigned"
    error_message = "delivery_identity = {} should default to the system-assigned identity."
  }

  assert {
    condition     = tolist(azurerm_eventgrid_system_topic_event_subscription.this["evgs-secret-rotation"].retry_policy)[0].max_delivery_attempts == 10
    error_message = "Explicit retry policies should render."
  }

  assert {
    condition     = tolist(azurerm_eventgrid_system_topic_event_subscription.this["evgs-secret-rotation"].storage_blob_dead_letter_destination)[0].storage_blob_container_name == "deadletter"
    error_message = "Dead letter destinations should render."
  }

  assert {
    condition     = azurerm_eventgrid_domain_topic.this["evgd-ldo-uks-tst-01/evgdt-orders"].name == "evgdt-orders"
    error_message = "Domain topics should flatten onto domain/topic composite keys."
  }

  assert {
    condition     = tolist(azurerm_eventgrid_event_subscription.this["evgs-rg-audit"].subject_filter)[0].subject_begins_with == "/subscriptions/"
    error_message = "Subject filters should render."
  }
}

# Validation: a subscription with two sources is rejected.
run "two_sources_are_rejected" {
  command = plan

  variables {
    event_subscriptions = {
      "evgs-broken" = {
        topic        = "evgt-ldo-uks-tst-01"
        system_topic = "egst-ldo-uks-tst-01"

        webhook_endpoint = { url = "https://example.com/hook" }
      }
    }
  }

  expect_failures = [var.event_subscriptions]
}

# Validation: a subscription with two endpoints is rejected.
run "two_endpoints_are_rejected" {
  command = plan

  variables {
    event_subscriptions = {
      "evgs-broken" = {
        topic = "evgt-ldo-uks-tst-01"

        webhook_endpoint     = { url = "https://example.com/hook" }
        eventhub_endpoint_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ldo-uks-tst-01/providers/Microsoft.EventHub/namespaces/evhns-ldo-uks-tst-01/eventhubs/evh-ldo-uks-tst-01"
      }
    }
  }

  expect_failures = [var.event_subscriptions]
}

# Validation: a topic reference that names no key in var.topics is rejected.
run "unknown_topic_reference_is_rejected" {
  command = plan

  variables {
    event_subscriptions = {
      "evgs-broken" = {
        topic = "evgt-does-not-exist"

        webhook_endpoint = { url = "https://example.com/hook" }
      }
    }
  }

  expect_failures = [var.event_subscriptions]
}

# Validation: Dynamic delivery properties need a source_field.
run "dynamic_delivery_property_without_source_is_rejected" {
  command = plan

  variables {
    event_subscriptions = {
      "evgs-broken" = {
        topic = "evgt-ldo-uks-tst-01"

        webhook_endpoint = { url = "https://example.com/hook" }

        delivery_properties = [
          { header_name = "x-correlation", type = "Dynamic" }
        ]
      }
    }
  }

  expect_failures = [var.event_subscriptions]
}

# Validation: input mappings only make sense on CustomEventSchema topics.
run "input_mapping_on_eventgridschema_is_rejected" {
  command = plan

  variables {
    topics = {
      "evgt-broken" = {
        input_mapping_fields = { subject = "payload.subject" }
      }
    }
  }

  expect_failures = [var.topics]
}
