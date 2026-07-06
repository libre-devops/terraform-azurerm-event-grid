output "domain_endpoints" {
  description = "Map of domain name to its publish endpoint."
  value       = { for k, v in azurerm_eventgrid_domain.this : k => v.endpoint }
}

output "domain_identities" {
  description = "Map of domain name to its identity { principal_id, tenant_id } when one is set."
  value = {
    for k, v in azurerm_eventgrid_domain.this : k => try({
      principal_id = v.identity[0].principal_id
      tenant_id    = v.identity[0].tenant_id
    }, null)
  }
}

output "domain_ids" {
  description = "Map of domain name to its resource id."
  value       = { for k, v in azurerm_eventgrid_domain.this : k => v.id }
}

output "domain_topic_ids" {
  description = "Map of domain/topic composite key to domain topic id."
  value       = { for k, v in azurerm_eventgrid_domain_topic.this : k => v.id }
}

output "event_subscription_ids" {
  description = "Map of subscription name to its resource id (both scoped and system topic subscriptions)."
  value = merge(
    { for k, v in azurerm_eventgrid_event_subscription.this : k => v.id },
    { for k, v in azurerm_eventgrid_system_topic_event_subscription.this : k => v.id }
  )
}

output "resource_group_name" {
  description = "Resource group name parsed from resource_group_id."
  value       = local.rg_name
}

output "subscription_id" {
  description = "Subscription id parsed from resource_group_id."
  value       = local.rg.subscription_id
}

output "system_topic_identities" {
  description = "Map of system topic name to its identity { principal_id, tenant_id } when one is set (for delivery_identity role assignments)."
  value = {
    for k, v in azurerm_eventgrid_system_topic.this : k => try({
      principal_id = v.identity[0].principal_id
      tenant_id    = v.identity[0].tenant_id
    }, null)
  }
}

output "system_topic_ids" {
  description = "Map of system topic name to its resource id."
  value       = { for k, v in azurerm_eventgrid_system_topic.this : k => v.id }
}

output "system_topic_ids_zipmap" {
  description = "Map of system topic name to a { name, id } object, for passing where both are needed together."
  value       = { for k, v in azurerm_eventgrid_system_topic.this : k => { name = v.name, id = v.id } }
}

output "system_topic_metric_arm_resource_ids" {
  description = "Map of system topic name to its metric ARM resource id."
  value       = { for k, v in azurerm_eventgrid_system_topic.this : k => v.metric_arm_resource_id }
}

output "tags" {
  description = "The base tags applied to the topics, system topics, and domains."
  value       = var.tags
}

output "topic_endpoints" {
  description = "Map of custom topic name to its publish endpoint."
  value       = { for k, v in azurerm_eventgrid_topic.this : k => v.endpoint }
}

output "topic_identities" {
  description = "Map of custom topic name to its identity { principal_id, tenant_id } when one is set."
  value = {
    for k, v in azurerm_eventgrid_topic.this : k => try({
      principal_id = v.identity[0].principal_id
      tenant_id    = v.identity[0].tenant_id
    }, null)
  }
}

output "topic_ids" {
  description = "Map of custom topic name to its resource id."
  value       = { for k, v in azurerm_eventgrid_topic.this : k => v.id }
}

output "topic_ids_zipmap" {
  description = "Map of custom topic name to a { name, id } object, for passing where both are needed together."
  value       = { for k, v in azurerm_eventgrid_topic.this : k => { name = v.name, id = v.id } }
}
