# Post-plan sanity checks: informational (warn), they never fail an apply.

check "has_resources" {
  assert {
    condition     = length(var.topics) + length(var.system_topics) + length(var.domains) + length(var.event_subscriptions) > 0
    error_message = "No topics, system topics, domains, or event subscriptions are defined: the module call creates nothing."
  }
}

# A topic or domain nobody subscribes to publishes into the void. Legal (subscriptions can live
# in other configurations), worth seeing.
check "sources_have_subscriptions" {
  assert {
    condition = alltrue(concat(
      [for t_name, t in var.topics : anytrue([for s in values(var.event_subscriptions) : s.topic == t_name])],
      [for st_name, st in var.system_topics : anytrue([for s in values(var.event_subscriptions) : s.system_topic == st_name])]
    ))
    error_message = "At least one topic or system topic here has no event subscription in this call: fine if subscribers live elsewhere, worth confirming."
  }
}

# Undeliverable events vanish after the retry budget unless a dead-letter destination exists.
# Deliberate for noisy fan-outs, dangerous for anything load-bearing.
check "subscriptions_have_dead_letter" {
  assert {
    condition     = alltrue([for s in values(var.event_subscriptions) : s.storage_blob_dead_letter_destination != null])
    error_message = "At least one event subscription has no dead-letter destination: undeliverable events are dropped once retries exhaust."
  }
}
