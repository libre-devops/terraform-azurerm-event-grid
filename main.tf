# Event Grid custom topics, system topics, domains (with domain topics), and event
# subscriptions. Subscriptions are one map targeting exactly one source each: a module topic,
# system topic, or domain by name, or any subscribable ARM id via scope. System topic
# subscriptions use their dedicated resource; everything else resolves to a scope on the generic
# resource. The resource group is passed by id and parsed.
locals {
  rg      = provider::azurerm::parse_resource_id(var.resource_group_id)
  rg_name = local.rg.resource_group_name

  domain_topics = {
    for pair in flatten([
      for d_name, d in var.domains : [
        for t_name in d.domain_topics : {
          key    = "${d_name}/${t_name}"
          d_name = d_name
          t_name = t_name
        }
      ]
    ]) : pair.key => pair
  }

  system_topic_subscriptions = {
    for k, s in var.event_subscriptions : k => s if s.system_topic != null
  }

  delivery_role_assignments = {
    for pair in flatten([
      for sub_name, sub in var.event_subscriptions : [
        for idx, ra in sub.delivery_identity_role_assignments : {
          key      = "${sub_name}/${idx}"
          sub_name = sub_name
          sub      = sub
          ra       = ra
        }
      ]
    ]) : pair.key => pair
  }

  scoped_subscriptions = {
    for k, s in var.event_subscriptions : k => merge(s, {
      resolved_scope = (
        s.scope != null ? s.scope :
        s.topic != null ? azurerm_eventgrid_topic.this[s.topic].id :
        azurerm_eventgrid_domain.this[s.domain].id
      )
    }) if s.system_topic == null
  }
}

resource "azurerm_eventgrid_topic" "this" {
  for_each = var.topics

  resource_group_name = local.rg_name
  location            = var.location
  tags                = each.value.tags != null ? each.value.tags : var.tags

  name = each.key

  input_schema                  = each.value.input_schema
  local_auth_enabled            = each.value.local_auth_enabled
  public_network_access_enabled = each.value.public_network_access_enabled

  inbound_ip_rule = [
    for r in each.value.inbound_ip_rules : {
      ip_mask = r.ip_mask
      action  = r.action
    }
  ]

  dynamic "identity" {
    for_each = each.value.identity != null ? [each.value.identity] : []

    content {
      type         = identity.value.type
      identity_ids = identity.value.identity_ids
    }
  }

  dynamic "input_mapping_fields" {
    for_each = each.value.input_mapping_fields != null ? [each.value.input_mapping_fields] : []

    content {
      id           = input_mapping_fields.value.id
      topic        = input_mapping_fields.value.topic
      event_type   = input_mapping_fields.value.event_type
      event_time   = input_mapping_fields.value.event_time
      data_version = input_mapping_fields.value.data_version
      subject      = input_mapping_fields.value.subject
    }
  }

  dynamic "input_mapping_default_values" {
    for_each = each.value.input_mapping_default_values != null ? [each.value.input_mapping_default_values] : []

    content {
      event_type   = input_mapping_default_values.value.event_type
      data_version = input_mapping_default_values.value.data_version
      subject      = input_mapping_default_values.value.subject
    }
  }
}

resource "azurerm_eventgrid_system_topic" "this" {
  for_each = var.system_topics

  resource_group_name = local.rg_name
  location            = var.location
  tags                = each.value.tags != null ? each.value.tags : var.tags

  name               = each.key
  source_resource_id = each.value.source_resource_id
  topic_type         = each.value.topic_type

  dynamic "identity" {
    for_each = each.value.identity != null ? [each.value.identity] : []

    content {
      type         = identity.value.type
      identity_ids = identity.value.identity_ids
    }
  }
}

resource "azurerm_eventgrid_domain" "this" {
  for_each = var.domains

  resource_group_name = local.rg_name
  location            = var.location
  tags                = each.value.tags != null ? each.value.tags : var.tags

  name = each.key

  input_schema                  = each.value.input_schema
  local_auth_enabled            = each.value.local_auth_enabled
  public_network_access_enabled = each.value.public_network_access_enabled

  auto_create_topic_with_first_subscription = each.value.auto_create_topic_with_first_subscription
  auto_delete_topic_with_last_subscription  = each.value.auto_delete_topic_with_last_subscription

  inbound_ip_rule = [
    for r in each.value.inbound_ip_rules : {
      ip_mask = r.ip_mask
      action  = r.action
    }
  ]

  dynamic "identity" {
    for_each = each.value.identity != null ? [each.value.identity] : []

    content {
      type         = identity.value.type
      identity_ids = identity.value.identity_ids
    }
  }
}

resource "azurerm_eventgrid_domain_topic" "this" {
  for_each = local.domain_topics

  resource_group_name = local.rg_name
  domain_name         = azurerm_eventgrid_domain.this[each.value.d_name].name

  name = each.value.t_name
}


# Delivery permission must exist BEFORE the subscription: Event Grid validates the delivery
# identity against the destination at create time (proven live: Managed Identity Authorization
# Error). The principal is the module-managed source's identity; the settle absorbs RBAC
# propagation before Event Grid checks.
resource "azurerm_role_assignment" "delivery" {
  for_each = local.delivery_role_assignments

  scope                = each.value.ra.scope
  role_definition_name = each.value.ra.role_definition_name
  principal_id = (
    each.value.sub.system_topic != null ? azurerm_eventgrid_system_topic.this[each.value.sub.system_topic].identity[0].principal_id :
    each.value.sub.topic != null ? azurerm_eventgrid_topic.this[each.value.sub.topic].identity[0].principal_id :
    azurerm_eventgrid_domain.this[each.value.sub.domain].identity[0].principal_id
  )
}

resource "time_sleep" "rbac_propagation" {
  count = length(local.delivery_role_assignments) > 0 ? 1 : 0

  create_duration = "60s"

  depends_on = [azurerm_role_assignment.delivery]
}

resource "azurerm_eventgrid_event_subscription" "this" {
  for_each = local.scoped_subscriptions

  depends_on = [time_sleep.rbac_propagation]

  scope = each.value.resolved_scope

  name = each.key

  event_delivery_schema = each.value.event_delivery_schema
  included_event_types  = each.value.included_event_types
  labels                = each.value.labels
  expiration_time_utc   = each.value.expiration_time_utc

  advanced_filtering_on_arrays_enabled = each.value.advanced_filtering_on_arrays_enabled

  eventhub_endpoint_id          = each.value.eventhub_endpoint_id
  service_bus_queue_endpoint_id = each.value.service_bus_queue_endpoint_id
  service_bus_topic_endpoint_id = each.value.service_bus_topic_endpoint_id
  hybrid_connection_endpoint_id = each.value.hybrid_connection_endpoint_id

  dynamic "webhook_endpoint" {
    for_each = each.value.webhook_endpoint != null ? [each.value.webhook_endpoint] : []

    content {
      url                               = webhook_endpoint.value.url
      max_events_per_batch              = webhook_endpoint.value.max_events_per_batch
      preferred_batch_size_in_kilobytes = webhook_endpoint.value.preferred_batch_size_in_kilobytes
      active_directory_tenant_id        = webhook_endpoint.value.active_directory_tenant_id
      active_directory_app_id_or_uri    = webhook_endpoint.value.active_directory_app_id_or_uri
    }
  }

  dynamic "azure_function_endpoint" {
    for_each = each.value.azure_function_endpoint != null ? [each.value.azure_function_endpoint] : []

    content {
      function_id                       = azure_function_endpoint.value.function_id
      max_events_per_batch              = azure_function_endpoint.value.max_events_per_batch
      preferred_batch_size_in_kilobytes = azure_function_endpoint.value.preferred_batch_size_in_kilobytes
    }
  }

  dynamic "storage_queue_endpoint" {
    for_each = each.value.storage_queue_endpoint != null ? [each.value.storage_queue_endpoint] : []

    content {
      storage_account_id                    = storage_queue_endpoint.value.storage_account_id
      queue_name                            = storage_queue_endpoint.value.queue_name
      queue_message_time_to_live_in_seconds = storage_queue_endpoint.value.queue_message_time_to_live_in_seconds
    }
  }

  dynamic "subject_filter" {
    for_each = each.value.subject_filter != null ? [each.value.subject_filter] : []

    content {
      subject_begins_with = subject_filter.value.subject_begins_with
      subject_ends_with   = subject_filter.value.subject_ends_with
      case_sensitive      = subject_filter.value.case_sensitive
    }
  }

  dynamic "advanced_filter" {
    for_each = each.value.advanced_filter != null ? [each.value.advanced_filter] : []

    content {
      dynamic "bool_equals" {
        for_each = advanced_filter.value.bool_equals
        content {
          key   = bool_equals.value.key
          value = bool_equals.value.value
        }
      }
      dynamic "is_not_null" {
        for_each = advanced_filter.value.is_not_null
        content {
          key = is_not_null.value.key
        }
      }
      dynamic "is_null_or_undefined" {
        for_each = advanced_filter.value.is_null_or_undefined
        content {
          key = is_null_or_undefined.value.key
        }
      }
      dynamic "number_greater_than" {
        for_each = advanced_filter.value.number_greater_than
        content {
          key   = number_greater_than.value.key
          value = number_greater_than.value.value
        }
      }
      dynamic "number_greater_than_or_equals" {
        for_each = advanced_filter.value.number_greater_than_or_equals
        content {
          key   = number_greater_than_or_equals.value.key
          value = number_greater_than_or_equals.value.value
        }
      }
      dynamic "number_less_than" {
        for_each = advanced_filter.value.number_less_than
        content {
          key   = number_less_than.value.key
          value = number_less_than.value.value
        }
      }
      dynamic "number_less_than_or_equals" {
        for_each = advanced_filter.value.number_less_than_or_equals
        content {
          key   = number_less_than_or_equals.value.key
          value = number_less_than_or_equals.value.value
        }
      }
      dynamic "number_in" {
        for_each = advanced_filter.value.number_in
        content {
          key    = number_in.value.key
          values = number_in.value.values
        }
      }
      dynamic "number_not_in" {
        for_each = advanced_filter.value.number_not_in
        content {
          key    = number_not_in.value.key
          values = number_not_in.value.values
        }
      }
      dynamic "number_in_range" {
        for_each = advanced_filter.value.number_in_range
        content {
          key    = number_in_range.value.key
          values = number_in_range.value.values
        }
      }
      dynamic "number_not_in_range" {
        for_each = advanced_filter.value.number_not_in_range
        content {
          key    = number_not_in_range.value.key
          values = number_not_in_range.value.values
        }
      }
      dynamic "string_begins_with" {
        for_each = advanced_filter.value.string_begins_with
        content {
          key    = string_begins_with.value.key
          values = string_begins_with.value.values
        }
      }
      dynamic "string_not_begins_with" {
        for_each = advanced_filter.value.string_not_begins_with
        content {
          key    = string_not_begins_with.value.key
          values = string_not_begins_with.value.values
        }
      }
      dynamic "string_ends_with" {
        for_each = advanced_filter.value.string_ends_with
        content {
          key    = string_ends_with.value.key
          values = string_ends_with.value.values
        }
      }
      dynamic "string_not_ends_with" {
        for_each = advanced_filter.value.string_not_ends_with
        content {
          key    = string_not_ends_with.value.key
          values = string_not_ends_with.value.values
        }
      }
      dynamic "string_contains" {
        for_each = advanced_filter.value.string_contains
        content {
          key    = string_contains.value.key
          values = string_contains.value.values
        }
      }
      dynamic "string_not_contains" {
        for_each = advanced_filter.value.string_not_contains
        content {
          key    = string_not_contains.value.key
          values = string_not_contains.value.values
        }
      }
      dynamic "string_in" {
        for_each = advanced_filter.value.string_in
        content {
          key    = string_in.value.key
          values = string_in.value.values
        }
      }
      dynamic "string_not_in" {
        for_each = advanced_filter.value.string_not_in
        content {
          key    = string_not_in.value.key
          values = string_not_in.value.values
        }
      }
    }
  }

  dynamic "delivery_identity" {
    for_each = each.value.delivery_identity != null ? [each.value.delivery_identity] : []

    content {
      type                   = delivery_identity.value.type
      user_assigned_identity = delivery_identity.value.user_assigned_identity
    }
  }

  dynamic "delivery_property" {
    for_each = each.value.delivery_properties

    content {
      header_name  = delivery_property.value.header_name
      type         = delivery_property.value.type
      value        = delivery_property.value.value
      source_field = delivery_property.value.source_field
      secret       = delivery_property.value.secret
    }
  }

  dynamic "retry_policy" {
    for_each = each.value.retry_policy != null ? [each.value.retry_policy] : []

    content {
      max_delivery_attempts = retry_policy.value.max_delivery_attempts
      event_time_to_live    = retry_policy.value.event_time_to_live
    }
  }

  dynamic "storage_blob_dead_letter_destination" {
    for_each = each.value.storage_blob_dead_letter_destination != null ? [each.value.storage_blob_dead_letter_destination] : []

    content {
      storage_account_id          = storage_blob_dead_letter_destination.value.storage_account_id
      storage_blob_container_name = storage_blob_dead_letter_destination.value.storage_blob_container_name
    }
  }

  dynamic "dead_letter_identity" {
    for_each = each.value.dead_letter_identity != null ? [each.value.dead_letter_identity] : []

    content {
      type                   = dead_letter_identity.value.type
      user_assigned_identity = dead_letter_identity.value.user_assigned_identity
    }
  }
}

resource "azurerm_eventgrid_system_topic_event_subscription" "this" {
  for_each = local.system_topic_subscriptions

  depends_on = [time_sleep.rbac_propagation]

  resource_group_name = local.rg_name
  system_topic        = azurerm_eventgrid_system_topic.this[each.value.system_topic].name

  name = each.key

  event_delivery_schema = each.value.event_delivery_schema
  included_event_types  = each.value.included_event_types
  labels                = each.value.labels
  expiration_time_utc   = each.value.expiration_time_utc

  advanced_filtering_on_arrays_enabled = each.value.advanced_filtering_on_arrays_enabled

  eventhub_endpoint_id          = each.value.eventhub_endpoint_id
  service_bus_queue_endpoint_id = each.value.service_bus_queue_endpoint_id
  service_bus_topic_endpoint_id = each.value.service_bus_topic_endpoint_id
  hybrid_connection_endpoint_id = each.value.hybrid_connection_endpoint_id

  dynamic "webhook_endpoint" {
    for_each = each.value.webhook_endpoint != null ? [each.value.webhook_endpoint] : []

    content {
      url                               = webhook_endpoint.value.url
      max_events_per_batch              = webhook_endpoint.value.max_events_per_batch
      preferred_batch_size_in_kilobytes = webhook_endpoint.value.preferred_batch_size_in_kilobytes
      active_directory_tenant_id        = webhook_endpoint.value.active_directory_tenant_id
      active_directory_app_id_or_uri    = webhook_endpoint.value.active_directory_app_id_or_uri
    }
  }

  dynamic "azure_function_endpoint" {
    for_each = each.value.azure_function_endpoint != null ? [each.value.azure_function_endpoint] : []

    content {
      function_id                       = azure_function_endpoint.value.function_id
      max_events_per_batch              = azure_function_endpoint.value.max_events_per_batch
      preferred_batch_size_in_kilobytes = azure_function_endpoint.value.preferred_batch_size_in_kilobytes
    }
  }

  dynamic "storage_queue_endpoint" {
    for_each = each.value.storage_queue_endpoint != null ? [each.value.storage_queue_endpoint] : []

    content {
      storage_account_id                    = storage_queue_endpoint.value.storage_account_id
      queue_name                            = storage_queue_endpoint.value.queue_name
      queue_message_time_to_live_in_seconds = storage_queue_endpoint.value.queue_message_time_to_live_in_seconds
    }
  }

  dynamic "subject_filter" {
    for_each = each.value.subject_filter != null ? [each.value.subject_filter] : []

    content {
      subject_begins_with = subject_filter.value.subject_begins_with
      subject_ends_with   = subject_filter.value.subject_ends_with
      case_sensitive      = subject_filter.value.case_sensitive
    }
  }

  dynamic "advanced_filter" {
    for_each = each.value.advanced_filter != null ? [each.value.advanced_filter] : []

    content {
      dynamic "bool_equals" {
        for_each = advanced_filter.value.bool_equals
        content {
          key   = bool_equals.value.key
          value = bool_equals.value.value
        }
      }
      dynamic "is_not_null" {
        for_each = advanced_filter.value.is_not_null
        content {
          key = is_not_null.value.key
        }
      }
      dynamic "is_null_or_undefined" {
        for_each = advanced_filter.value.is_null_or_undefined
        content {
          key = is_null_or_undefined.value.key
        }
      }
      dynamic "number_greater_than" {
        for_each = advanced_filter.value.number_greater_than
        content {
          key   = number_greater_than.value.key
          value = number_greater_than.value.value
        }
      }
      dynamic "number_greater_than_or_equals" {
        for_each = advanced_filter.value.number_greater_than_or_equals
        content {
          key   = number_greater_than_or_equals.value.key
          value = number_greater_than_or_equals.value.value
        }
      }
      dynamic "number_less_than" {
        for_each = advanced_filter.value.number_less_than
        content {
          key   = number_less_than.value.key
          value = number_less_than.value.value
        }
      }
      dynamic "number_less_than_or_equals" {
        for_each = advanced_filter.value.number_less_than_or_equals
        content {
          key   = number_less_than_or_equals.value.key
          value = number_less_than_or_equals.value.value
        }
      }
      dynamic "number_in" {
        for_each = advanced_filter.value.number_in
        content {
          key    = number_in.value.key
          values = number_in.value.values
        }
      }
      dynamic "number_not_in" {
        for_each = advanced_filter.value.number_not_in
        content {
          key    = number_not_in.value.key
          values = number_not_in.value.values
        }
      }
      dynamic "number_in_range" {
        for_each = advanced_filter.value.number_in_range
        content {
          key    = number_in_range.value.key
          values = number_in_range.value.values
        }
      }
      dynamic "number_not_in_range" {
        for_each = advanced_filter.value.number_not_in_range
        content {
          key    = number_not_in_range.value.key
          values = number_not_in_range.value.values
        }
      }
      dynamic "string_begins_with" {
        for_each = advanced_filter.value.string_begins_with
        content {
          key    = string_begins_with.value.key
          values = string_begins_with.value.values
        }
      }
      dynamic "string_not_begins_with" {
        for_each = advanced_filter.value.string_not_begins_with
        content {
          key    = string_not_begins_with.value.key
          values = string_not_begins_with.value.values
        }
      }
      dynamic "string_ends_with" {
        for_each = advanced_filter.value.string_ends_with
        content {
          key    = string_ends_with.value.key
          values = string_ends_with.value.values
        }
      }
      dynamic "string_not_ends_with" {
        for_each = advanced_filter.value.string_not_ends_with
        content {
          key    = string_not_ends_with.value.key
          values = string_not_ends_with.value.values
        }
      }
      dynamic "string_contains" {
        for_each = advanced_filter.value.string_contains
        content {
          key    = string_contains.value.key
          values = string_contains.value.values
        }
      }
      dynamic "string_not_contains" {
        for_each = advanced_filter.value.string_not_contains
        content {
          key    = string_not_contains.value.key
          values = string_not_contains.value.values
        }
      }
      dynamic "string_in" {
        for_each = advanced_filter.value.string_in
        content {
          key    = string_in.value.key
          values = string_in.value.values
        }
      }
      dynamic "string_not_in" {
        for_each = advanced_filter.value.string_not_in
        content {
          key    = string_not_in.value.key
          values = string_not_in.value.values
        }
      }
    }
  }

  dynamic "delivery_identity" {
    for_each = each.value.delivery_identity != null ? [each.value.delivery_identity] : []

    content {
      type                   = delivery_identity.value.type
      user_assigned_identity = delivery_identity.value.user_assigned_identity
    }
  }

  dynamic "delivery_property" {
    for_each = each.value.delivery_properties

    content {
      header_name  = delivery_property.value.header_name
      type         = delivery_property.value.type
      value        = delivery_property.value.value
      source_field = delivery_property.value.source_field
      secret       = delivery_property.value.secret
    }
  }

  dynamic "retry_policy" {
    for_each = each.value.retry_policy != null ? [each.value.retry_policy] : []

    content {
      max_delivery_attempts = retry_policy.value.max_delivery_attempts
      event_time_to_live    = retry_policy.value.event_time_to_live
    }
  }

  dynamic "storage_blob_dead_letter_destination" {
    for_each = each.value.storage_blob_dead_letter_destination != null ? [each.value.storage_blob_dead_letter_destination] : []

    content {
      storage_account_id          = storage_blob_dead_letter_destination.value.storage_account_id
      storage_blob_container_name = storage_blob_dead_letter_destination.value.storage_blob_container_name
    }
  }

  dynamic "dead_letter_identity" {
    for_each = each.value.dead_letter_identity != null ? [each.value.dead_letter_identity] : []

    content {
      type                   = dead_letter_identity.value.type
      user_assigned_identity = dead_letter_identity.value.user_assigned_identity
    }
  }
}
