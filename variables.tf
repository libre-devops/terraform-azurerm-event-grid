variable "domains" {
  description = <<-EOT
    Event Grid domains keyed by name: multi-tenant ingestion endpoints whose domain topics are
    lightweight children (domain_topics is a set of names). Subscriptions attach through
    event_subscriptions with domain = "<name>". Same posture as topics: local_auth_enabled
    defaults to false.
  EOT
  type = map(object({
    tags = optional(map(string))

    input_schema                  = optional(string, "EventGridSchema")
    local_auth_enabled            = optional(bool, false)
    public_network_access_enabled = optional(bool, true)

    auto_create_topic_with_first_subscription = optional(bool, true)
    auto_delete_topic_with_last_subscription  = optional(bool, true)

    inbound_ip_rules = optional(list(object({
      ip_mask = string
      action  = optional(string, "Allow")
    })), [])

    identity = optional(object({
      type         = optional(string, "SystemAssigned")
      identity_ids = optional(set(string))
    }))

    domain_topics = optional(set(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for d in values(var.domains) : contains(["CloudEventSchemaV1_0", "CustomEventSchema", "EventGridSchema"], d.input_schema)])
    error_message = "input_schema must be EventGridSchema, CloudEventSchemaV1_0, or CustomEventSchema."
  }
}

variable "event_subscriptions" {
  description = <<-EOT
    Event subscriptions keyed by name. Each targets exactly one source: a custom topic from this
    module (topic = "<name>"), a system topic from this module (system_topic = "<name>"), a
    domain from this module (domain = "<name>"), or any subscribable ARM id (scope = "<id>",
    for example a subscription, resource group, or storage account).

    Each delivers to exactly one endpoint: webhook_endpoint, azure_function_endpoint,
    storage_queue_endpoint, or one of the *_endpoint_id strings (event hub, service bus queue
    or topic, hybrid connection). delivery_identity lets Event Grid deliver with the source's
    managed identity (the private-target pattern); storage_blob_dead_letter_destination and
    retry_policy make failure handling explicit.
  EOT
  type = map(object({
    scope        = optional(string)
    topic        = optional(string)
    system_topic = optional(string)
    domain       = optional(string)

    event_delivery_schema = optional(string, "EventGridSchema")
    included_event_types  = optional(list(string))
    labels                = optional(list(string))
    expiration_time_utc   = optional(string)

    advanced_filtering_on_arrays_enabled = optional(bool, false)

    subject_filter = optional(object({
      subject_begins_with = optional(string)
      subject_ends_with   = optional(string)
      case_sensitive      = optional(bool)
    }))

    advanced_filter = optional(object({
      bool_equals                   = optional(list(object({ key = string, value = bool })), [])
      is_not_null                   = optional(list(object({ key = string })), [])
      is_null_or_undefined          = optional(list(object({ key = string })), [])
      number_greater_than           = optional(list(object({ key = string, value = number })), [])
      number_greater_than_or_equals = optional(list(object({ key = string, value = number })), [])
      number_less_than              = optional(list(object({ key = string, value = number })), [])
      number_less_than_or_equals    = optional(list(object({ key = string, value = number })), [])
      number_in                     = optional(list(object({ key = string, values = list(number) })), [])
      number_not_in                 = optional(list(object({ key = string, values = list(number) })), [])
      number_in_range               = optional(list(object({ key = string, values = list(list(number)) })), [])
      number_not_in_range           = optional(list(object({ key = string, values = list(list(number)) })), [])
      string_begins_with            = optional(list(object({ key = string, values = list(string) })), [])
      string_not_begins_with        = optional(list(object({ key = string, values = list(string) })), [])
      string_ends_with              = optional(list(object({ key = string, values = list(string) })), [])
      string_not_ends_with          = optional(list(object({ key = string, values = list(string) })), [])
      string_contains               = optional(list(object({ key = string, values = list(string) })), [])
      string_not_contains           = optional(list(object({ key = string, values = list(string) })), [])
      string_in                     = optional(list(object({ key = string, values = list(string) })), [])
      string_not_in                 = optional(list(object({ key = string, values = list(string) })), [])
    }))

    webhook_endpoint = optional(object({
      url                               = string
      max_events_per_batch              = optional(number)
      preferred_batch_size_in_kilobytes = optional(number)
      active_directory_tenant_id        = optional(string)
      active_directory_app_id_or_uri    = optional(string)
    }))

    azure_function_endpoint = optional(object({
      function_id                       = string
      max_events_per_batch              = optional(number)
      preferred_batch_size_in_kilobytes = optional(number)
    }))

    storage_queue_endpoint = optional(object({
      storage_account_id                    = string
      queue_name                            = string
      queue_message_time_to_live_in_seconds = optional(number)
    }))

    eventhub_endpoint_id          = optional(string)
    service_bus_queue_endpoint_id = optional(string)
    service_bus_topic_endpoint_id = optional(string)
    hybrid_connection_endpoint_id = optional(string)

    delivery_identity = optional(object({
      type                   = optional(string, "SystemAssigned")
      user_assigned_identity = optional(string)
    }))

    # Role assignments the SOURCE's managed identity needs on the destination, created by the
    # module BETWEEN the source and the subscription: Event Grid validates delivery permission
    # at subscription-create time (proven live), so consumer-side assignments arrive too late.
    delivery_identity_role_assignments = optional(list(object({
      scope                = string
      role_definition_name = string
    })), [])

    delivery_properties = optional(list(object({
      header_name  = string
      type         = string
      value        = optional(string)
      source_field = optional(string)
      secret       = optional(bool)
    })), [])

    retry_policy = optional(object({
      max_delivery_attempts = number
      event_time_to_live    = number
    }))

    storage_blob_dead_letter_destination = optional(object({
      storage_account_id          = string
      storage_blob_container_name = string
    }))

    dead_letter_identity = optional(object({
      type                   = optional(string, "SystemAssigned")
      user_assigned_identity = optional(string)
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for s in values(var.event_subscriptions) :
      length([for src in [s.scope, s.topic, s.system_topic, s.domain] : src if src != null]) == 1
    ])
    error_message = "every event subscription targets exactly one source: scope, topic, system_topic, or domain."
  }

  validation {
    condition     = alltrue([for s in values(var.event_subscriptions) : s.topic == null || contains(keys(var.topics), coalesce(s.topic, "-"))])
    error_message = "event subscription topic references must name a key in var.topics."
  }

  validation {
    condition     = alltrue([for s in values(var.event_subscriptions) : s.system_topic == null || contains(keys(var.system_topics), coalesce(s.system_topic, "-"))])
    error_message = "event subscription system_topic references must name a key in var.system_topics."
  }

  validation {
    condition     = alltrue([for s in values(var.event_subscriptions) : s.domain == null || contains(keys(var.domains), coalesce(s.domain, "-"))])
    error_message = "event subscription domain references must name a key in var.domains."
  }

  validation {
    condition = alltrue([
      for s in values(var.event_subscriptions) :
      length(concat(
        [for e in [s.webhook_endpoint, s.azure_function_endpoint, s.storage_queue_endpoint] : e if e != null],
        [for e in [s.eventhub_endpoint_id, s.service_bus_queue_endpoint_id, s.service_bus_topic_endpoint_id, s.hybrid_connection_endpoint_id] : e if e != null]
      )) == 1
    ])
    error_message = "every event subscription delivers to exactly one endpoint."
  }

  validation {
    condition     = alltrue([for s in values(var.event_subscriptions) : contains(["CloudEventSchemaV1_0", "CustomInputSchema", "EventGridSchema"], s.event_delivery_schema)])
    error_message = "event_delivery_schema must be EventGridSchema, CloudEventSchemaV1_0, or CustomInputSchema."
  }

  validation {
    condition = alltrue([
      for s in values(var.event_subscriptions) : alltrue([
        for p in s.delivery_properties :
        p.type == "Static" ? p.value != null : (p.type == "Dynamic" && p.source_field != null)
      ])
    ])
    error_message = "delivery properties are Static with a value, or Dynamic with a source_field."
  }

  validation {
    condition = alltrue([
      for s in values(var.event_subscriptions) :
      s.delivery_identity == null ? true : contains(["SystemAssigned", "UserAssigned"], s.delivery_identity.type)
    ])
    error_message = "delivery_identity type must be SystemAssigned or UserAssigned."
  }

  validation {
    condition = alltrue([
      for s in values(var.event_subscriptions) :
      s.dead_letter_identity == null ? true : contains(["SystemAssigned", "UserAssigned"], s.dead_letter_identity.type)
    ])
    error_message = "dead_letter_identity type must be SystemAssigned or UserAssigned."
  }

  validation {
    condition = alltrue([
      for s in values(var.event_subscriptions) :
      s.dead_letter_identity == null || s.storage_blob_dead_letter_destination != null
    ])
    error_message = "dead_letter_identity needs a storage_blob_dead_letter_destination to authenticate to."
  }

  validation {
    condition = alltrue([
      for s in values(var.event_subscriptions) :
      length(s.delivery_identity_role_assignments) == 0 || (
        s.system_topic != null ? try(var.system_topics[s.system_topic].identity, null) != null :
        s.topic != null ? try(var.topics[s.topic].identity, null) != null :
        s.domain != null ? try(var.domains[s.domain].identity, null) != null : false
      )
    ])
    error_message = "delivery_identity_role_assignments need a module-managed source (topic, system_topic, or domain) that has an identity block: the assignments are granted to that source's identity."
  }
}

variable "location" {
  description = "Azure region for the topics and domains (system topics follow their source's region, global for subscription and resource group sources)."
  type        = string
}

variable "resource_group_id" {
  description = "Resource id of the resource group the resources are created in. The resource group name and subscription are parsed from this id."
  type        = string

  validation {
    condition     = try(provider::azurerm::parse_resource_id(var.resource_group_id).resource_type, "") == "resourceGroups"
    error_message = "resource_group_id must be a resource group resource id."
  }
}

variable "system_topics" {
  description = <<-EOT
    Event Grid system topics keyed by name: the event feed of an existing Azure resource
    (Key Vault, storage account, resource group, subscription). source_resource_id is the
    emitting resource; topic_type is its system topic type (for example Microsoft.KeyVault.vaults
    or Microsoft.Storage.StorageAccounts; list them with az eventgrid topic-type list).
    Subscriptions attach through event_subscriptions with system_topic = "<name>".
  EOT
  type = map(object({
    source_resource_id = string
    topic_type         = string
    tags               = optional(map(string))

    identity = optional(object({
      type         = optional(string, "SystemAssigned")
      identity_ids = optional(set(string))
    }))
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to the topics, system topics, and domains (unless one sets its own)."
  type        = map(string)
  default     = {}
}

variable "topics" {
  description = <<-EOT
    Event Grid custom topics keyed by name: endpoints your own applications publish to.
    local_auth_enabled defaults to FALSE, so the access keys are off and publishers authenticate
    with Entra ID (EventGrid Data Sender role). Subscriptions attach through event_subscriptions
    with topic = "<name>". input_mapping applies only to CustomEventSchema topics.
  EOT
  type = map(object({
    tags = optional(map(string))

    input_schema                  = optional(string, "EventGridSchema")
    local_auth_enabled            = optional(bool, false)
    public_network_access_enabled = optional(bool, true)

    inbound_ip_rules = optional(list(object({
      ip_mask = string
      action  = optional(string, "Allow")
    })), [])

    identity = optional(object({
      type         = optional(string, "SystemAssigned")
      identity_ids = optional(set(string))
    }))

    input_mapping_fields = optional(object({
      id           = optional(string)
      topic        = optional(string)
      event_type   = optional(string)
      event_time   = optional(string)
      data_version = optional(string)
      subject      = optional(string)
    }))

    input_mapping_default_values = optional(object({
      event_type   = optional(string)
      data_version = optional(string)
      subject      = optional(string)
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for t in values(var.topics) : contains(["CloudEventSchemaV1_0", "CustomEventSchema", "EventGridSchema"], t.input_schema)])
    error_message = "input_schema must be EventGridSchema, CloudEventSchemaV1_0, or CustomEventSchema."
  }

  validation {
    condition = alltrue([
      for t in values(var.topics) :
      (t.input_mapping_fields == null && t.input_mapping_default_values == null) || t.input_schema == "CustomEventSchema"
    ])
    error_message = "input mappings apply only to CustomEventSchema topics."
  }
}
